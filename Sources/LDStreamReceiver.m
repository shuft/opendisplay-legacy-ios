// Section references (§) are to OpenDisplay's PROTOCOL.md, pv 3:
// https://github.com/peetzweg/opendisplay/blob/main/PROTOCOL.md

#import "LDStreamReceiver.h"
#import "LDLog.h"
#import <CoreMedia/CoreMedia.h>
#import <Network/Network.h>
#import <QuartzCore/QuartzCore.h>
#import <arpa/inet.h>
#import <sys/utsname.h>

static const char *const kPort = "9000";
static const char *const kServiceType = "_opensidecar._tcp";
static const NSInteger kProtocolVersion = 3;

// §8.2: both ends ping every 2 s and give up after 5 s of silence.
static const NSTimeInterval kSilenceTimeout = 5.0;
static const unsigned kPingEveryTicks = 2;
static const unsigned kStatsEveryTicks = 5;

// Guard against a corrupt length prefix swallowing all memory.
static const uint32_t kMaxFrameLength = 32u << 20;
static const int kMaxNALUs = 64;

static double LDNowMs(void) {
    return [NSDate date].timeIntervalSince1970 * 1000.0;
}

static double LDNumber(id value, double fallback) {
    return [value isKindOfClass:NSNumber.class] ? [value doubleValue] : fallback;
}

/// Stable per-install identity (§2.1, §6.1): lets the Mac recognize the same
/// iPad across USB and Wi-Fi.
static NSString *LDInstallID(void) {
    static NSString *installID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        installID = [defaults stringForKey:@"LDInstallID"];
        if (!installID) {
            installID = NSUUID.UUID.UUIDString;
            [defaults setObject:installID forKey:@"LDInstallID"];
        }
    });
    return installID;
}

/// DNS-SD TXT wire format: each entry is a length byte then "key=value".
static NSData *LDTXTRecord(NSDictionary<NSString *, NSString *> *entries) {
    NSMutableData *txt = [NSMutableData data];
    for (NSString *key in entries) {
        NSData *entry = [[NSString stringWithFormat:@"%@=%@", key, entries[key]]
            dataUsingEncoding:NSUTF8StringEncoding];
        uint8_t length = (uint8_t)MIN(entry.length, 255u);
        [txt appendBytes:&length length:1];
        [txt appendBytes:entry.bytes length:length];
    }
    return txt;
}

/// H.264 throughput ceiling for §6.5 `videoCaps`, or nil for no limit.
/// A7/A8 decoders are specified to Level 4.2 (522,240 macroblocks/s); a
/// 2048x1536 panel at 60 fps needs ~189 Mpx/s, so without this the Mac
/// streams faster than the iPad can decode and the picture lags behind.
static NSNumber *LDDecodeBudget(void) {
    struct utsname system;
    uname(&system);
    NSString *model = @(system.machine);
    for (NSString *prefix in @[ @"iPad4,", @"iPad5,", @"iPhone6,", @"iPhone7," ]) {
        if ([model hasPrefix:prefix]) return @(522240 * 256);
    }
    return nil;
}

/// usbmuxd delivers cable connections from loopback (§2.2); anything else
/// came over the network.
static NSString *LDTransportFor(nw_connection_t connection) {
    nw_endpoint_t endpoint = nw_connection_copy_endpoint(connection);
    if (nw_endpoint_get_type(endpoint) != nw_endpoint_type_address) return @"WiFi";
    const struct sockaddr *address = nw_endpoint_get_address(endpoint);
    if (address->sa_family == AF_INET) {
        const struct sockaddr_in *v4 = (const struct sockaddr_in *)address;
        if ((ntohl(v4->sin_addr.s_addr) >> 24) == 127) return @"USB";
    } else if (address->sa_family == AF_INET6) {
        const struct sockaddr_in6 *v6 = (const struct sockaddr_in6 *)address;
        if (IN6_IS_ADDR_LOOPBACK(&v6->sin6_addr)) return @"USB";
        if (IN6_IS_ADDR_V4MAPPED(&v6->sin6_addr) && v6->sin6_addr.s6_addr[12] == 127) return @"USB";
    }
    return @"WiFi";
}

typedef struct {
    size_t start;
    size_t length;
} LDRange;

@implementation LDStreamReceiver {
    AVSampleBufferDisplayLayer *_displayLayer;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    unsigned _ticks;

    // Everything below is only touched on _queue.
    NSString *_deviceName;
    NSString *_deviceKind;
    NSInteger _maxFrameRate;
    NSInteger _pixelsWide;
    NSInteger _pixelsHigh;
    double _scale;

    nw_listener_t _listener;
    BOOL _listenerHealthy;
    BOOL _asleep;

    nw_connection_t _connection;
    BOOL _connectionReady;
    NSMutableArray<nw_connection_t> *_pending;
    NSString *_transport;
    NSMutableData *_buffer;
    CFTimeInterval _lastReceived;

    NSInteger _senderVersion;
    NSMutableArray<NSArray<NSNumber *> *> *_clockSamples;
    BOOL _offsetKnown;
    double _clockOffset;
    double _lastRTT;
    long long _lastCursorSeq;
    CGPoint _cursorPoint;
    NSMutableSet<NSString *> *_ignoredTypes;

    NSData *_sps;
    NSData *_pps;
    CMVideoFormatDescriptionRef _format;
    BOOL _paused;
    BOOL _awaitingKeyframe;
    CFTimeInterval _lastKeyframeRequest;

    NSUInteger _statFrames;
    NSUInteger _statEnqueued;
    NSUInteger _statBytes;
    NSUInteger _statKeyframeRequests;
    CFTimeInterval _statStart;
}

- (instancetype)initWithDisplayLayer:(AVSampleBufferDisplayLayer *)displayLayer {
    if ((self = [super init])) {
        _displayLayer = displayLayer;
        _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        _queue = dispatch_queue_create("legacydisplay.receiver", DISPATCH_QUEUE_SERIAL);
        _pending = [NSMutableArray array];
        _buffer = [NSMutableData data];
        _clockSamples = [NSMutableArray array];
        _ignoredTypes = [NSMutableSet set];
        _transport = @"-";
        _senderVersion = 1;
        _scale = 2;

        UIDevice *device = UIDevice.currentDevice;
        _deviceName = device.name;
        _deviceKind = device.userInterfaceIdiom == UIUserInterfaceIdiomPad ? @"iPad" : @"iPhone";
        _maxFrameRate = UIScreen.mainScreen.maximumFramesPerSecond ?: 60;
    }
    return self;
}

- (void)dealloc {
    if (_format) CFRelease(_format);
}

#pragma mark - Public

- (void)setPanelPixelsWide:(NSInteger)wide high:(NSInteger)high scale:(double)scale {
    dispatch_async(_queue, ^{
        if (wide == self->_pixelsWide && high == self->_pixelsHigh && scale == self->_scale) return;
        self->_pixelsWide = wide;
        self->_pixelsHigh = high;
        self->_scale = scale;
        LDLog(@"panel %ldx%ld @%gx", (long)wide, (long)high, scale);
        // §6.1: rotation is a re-hello on the live connection, not a reconnect.
        if (self->_connection && self->_connectionReady) [self sendHelloOn:self->_connection];
    });
}

- (void)start {
    dispatch_async(_queue, ^{
        if (self->_timer) return;
        [self startListener];
        self->_statStart = CACurrentMediaTime();
        self->_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_queue);
        dispatch_source_set_timer(self->_timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                  NSEC_PER_SEC, NSEC_PER_SEC / 10);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(self->_timer, ^{
            [weakSelf tick];
        });
        dispatch_resume(self->_timer);
    });
}

- (void)resume {
    dispatch_async(_queue, ^{
        BOOL wasAway = self->_paused || self->_asleep;
        self->_asleep = NO;
        if (!self->_timer) return;  // not started yet
        // A suspended app's listener can die without reporting it, so after
        // time away with no live session, always start fresh.
        if (!self->_listenerHealthy || (wasAway && !self->_connection)) [self restartListener];
        if (self->_paused) {
            self->_paused = NO;
            [self->_displayLayer flush];
            self->_awaitingKeyframe = YES;
            [self requestKeyframe];
        }
    });
}

- (void)pause {
    dispatch_async(_queue, ^{
        self->_paused = YES;
    });
}

- (void)enterSleep {
    dispatch_async(_queue, ^{
        // §6.1 `sleeping`: the Mac drops the virtual display and waits for us.
        // Stop listening too, or its wake redials would rebuild the display
        // while nobody can see it.
        [self closeSessionAnnouncing:@"sleeping" completion:nil];
        self->_asleep = YES;
        [self setStatus:@"Asleep: reconnects when unlocked"];
    });
}

- (void)shutDownWaitingUpTo:(NSTimeInterval)timeout {
    dispatch_semaphore_t sent = dispatch_semaphore_create(0);
    dispatch_async(_queue, ^{
        [self closeSessionAnnouncing:@"closing" completion:^{
            dispatch_semaphore_signal(sent);
        }];
    });
    dispatch_semaphore_wait(sent, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
}

- (void)sendTouchPhase:(NSString *)phase x:(double)x y:(double)y {
    double now = LDNowMs();
    dispatch_async(_queue, ^{
        NSMutableDictionary *message =
            [@{ @"type" : @"touch", @"phase" : phase, @"x" : @(x), @"y" : @(y) } mutableCopy];
        // §6.1: `t` is in the sender's clock, and only once the offset is known.
        if (self->_offsetKnown) message[@"t"] = @(round(now + self->_clockOffset));
        [self sendControl:message on:self->_connection completion:nil];
    });
}

- (void)sendScrollDx:(double)dx dy:(double)dy {
    dispatch_async(_queue, ^{
        [self sendControl:@{ @"type" : @"scroll", @"dx" : @(dx), @"dy" : @(dy) }
                       on:self->_connection
               completion:nil];
    });
}

#pragma mark - Listener

- (void)startListener {
    nw_parameters_t parameters = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL, ^(nw_protocol_options_t tcp) {
            // §1: input events are tiny packets; Nagle's batching reads as input lag.
            nw_tcp_options_set_no_delay(tcp, true);
        });
    nw_parameters_set_reuse_local_address(parameters, true);
    nw_listener_t listener = nw_listener_create_with_port(kPort, parameters);
    if (!listener) {
        [self setStatus:@"Couldn't open port 9000"];
        return;
    }

    // §2.1: TXT `id` must match hello's, `pv` lets the Mac check compatibility
    // before dialing. The cable path ignores Bonjour entirely.
    nw_advertise_descriptor_t advertise =
        nw_advertise_descriptor_create_bonjour_service(_deviceName.UTF8String, kServiceType, NULL);
    NSData *txt = LDTXTRecord(@{ @"id" : LDInstallID(), @"pv" : @(kProtocolVersion).stringValue });
    nw_advertise_descriptor_set_txt_record(advertise, txt.bytes, txt.length);
    nw_listener_set_advertise_descriptor(listener, advertise);

    __weak typeof(self) weakSelf = self;
    nw_listener_set_queue(listener, _queue);
    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
        [weakSelf listener:listener changedState:state error:error];
    });
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
        [weakSelf accept:connection];
    });
    _listener = listener;
    _listenerHealthy = YES;
    nw_listener_start(listener);
}

- (void)restartListener {
    [self cancelListener];
    [self startListener];
}

- (void)cancelListener {
    nw_listener_t listener = _listener;
    _listener = nil;
    _listenerHealthy = NO;
    if (listener) nw_listener_cancel(listener);
}

- (void)listener:(nw_listener_t)listener changedState:(nw_listener_state_t)state error:(nw_error_t)error {
    if (listener != _listener) return;
    switch (state) {
    case nw_listener_state_ready:
        LDLog(@"listening on :%s", kPort);
        if (!_connection) [self setStatus:@"Waiting for your Mac"];
        break;
    case nw_listener_state_failed: {
        LDLog(@"listener failed: %d", error ? nw_error_get_error_code(error) : 0);
        _listenerHealthy = NO;
        [self setStatus:@"Listener failed, retrying"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), _queue, ^{
            if (self->_listener == listener && !self->_asleep) [self restartListener];
        });
        break;
    }
    case nw_listener_state_cancelled:
        _listenerHealthy = NO;
        break;
    default:
        break;
    }
}

#pragma mark - Connections

- (void)accept:(nw_connection_t)connection {
    NSString *transport = LDTransportFor(connection);
    LDLog(@"inbound connection (%@)", transport);
    if (_asleep) {
        nw_connection_cancel(connection);
        return;
    }
    if (!_connection) {
        [self adopt:connection transport:transport firstBytes:nil];
        return;
    }

    // §1 says a newcomer replaces the live session, but a Bonjour dial races
    // IPv4 and IPv6 and the Mac cancels the loser within milliseconds.
    // Adopting it on sight would evict the winner, so like the official
    // receiver, greet it and adopt it only once it sends bytes back.
    [_pending addObject:connection];
    __weak typeof(self) weakSelf = self;
    nw_connection_set_queue(connection, _queue);
    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (state == nw_connection_state_ready) {
            [strongSelf sendHelloOn:connection];
            nw_connection_receive(connection, 1, 1 << 18,
                ^(dispatch_data_t content, nw_content_context_t context, bool isComplete, nw_error_t receiveError) {
                    typeof(self) receiver = weakSelf;
                    if (!receiver || ![receiver->_pending containsObject:connection]) return;
                    [receiver->_pending removeObject:connection];
                    if (content && !receiveError && !isComplete) {
                        LDLog(@"newcomer proved itself, adopting it");
                        [receiver adopt:connection transport:transport firstBytes:content];
                    } else {
                        nw_connection_cancel(connection);
                    }
                });
        } else if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) {
            [strongSelf->_pending removeObject:connection];
        }
    });
    nw_connection_start(connection);
}

/// `firstBytes` is set for a newcomer that is already started and greeted.
- (void)adopt:(nw_connection_t)connection transport:(NSString *)transport firstBytes:(dispatch_data_t)firstBytes {
    for (nw_connection_t rival in _pending) {
        if (rival != connection) nw_connection_cancel(rival);
    }
    [_pending removeAllObjects];
    nw_connection_t previous = _connection;
    _connection = nil;
    if (previous) nw_connection_cancel(previous);
    [self resetSession];

    _connection = connection;
    _transport = transport;
    _lastReceived = CACurrentMediaTime();
    __weak typeof(self) weakSelf = self;
    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
        [weakSelf connection:connection changedState:state error:error];
    });
    if (firstBytes) {
        _connectionReady = YES;
        [self setConnected:YES];
        [self didReceive:firstBytes];
    } else {
        nw_connection_set_queue(connection, _queue);
        nw_connection_start(connection);
    }
    if (_connection == connection) [self receiveOn:connection];
}

- (void)connection:(nw_connection_t)connection changedState:(nw_connection_state_t)state error:(nw_error_t)error {
    if (connection != _connection) return;
    switch (state) {
    case nw_connection_state_ready:
        if (_connectionReady) break;
        _connectionReady = YES;
        _lastReceived = CACurrentMediaTime();
        // §6.1: hello first, on every connection; the Mac can do nothing until it arrives.
        [self sendHelloOn:connection];
        [self setConnected:YES];
        break;
    case nw_connection_state_failed:
        [self drop:connection reason:@"connection failed"];
        break;
    case nw_connection_state_cancelled:
        [self drop:connection reason:@"connection cancelled"];
        break;
    default:
        break;
    }
}

- (void)drop:(nw_connection_t)connection reason:(NSString *)reason {
    if (!connection || connection != _connection) return;
    LDLog(@"session ended: %@", reason);
    _connection = nil;
    nw_connection_cancel(connection);
    [self resetSession];
    [self setConnected:NO];
    if (!_asleep) [self setStatus:@"Waiting for your Mac"];
}

- (void)resetSession {
    _connectionReady = NO;
    _buffer.length = 0;
    _senderVersion = 1;
    [_clockSamples removeAllObjects];
    _offsetKnown = NO;
    _lastCursorSeq = 0;
    _sps = nil;
    _pps = nil;
    if (_format) {
        CFRelease(_format);
        _format = NULL;
    }
    _awaitingKeyframe = NO;
    [_displayLayer flushAndRemoveImage];
    _statFrames = _statEnqueued = _statBytes = _statKeyframeRequests = 0;
    _statStart = CACurrentMediaTime();
}

- (void)closeSessionAnnouncing:(NSString *)type completion:(void (^)(void))completion {
    for (nw_connection_t candidate in _pending) nw_connection_cancel(candidate);
    [_pending removeAllObjects];
    [self cancelListener];

    nw_connection_t connection = _connection;
    if (!connection || !_connectionReady) {
        [self drop:connection reason:type];
        if (completion) completion();
        return;
    }
    // Best effort (§6.1): close once the goodbye is on the wire.
    [self sendControl:@{ @"type" : type } on:connection completion:^{
        nw_connection_cancel(connection);
        if (completion) completion();
    }];
    _connection = nil;
    LDLog(@"session ended: %@", type);
    [self resetSession];
    [self setConnected:NO];
}

#pragma mark - Sending

- (void)sendHelloOn:(nw_connection_t)connection {
    // §6.5: H.264 only (these chips have no HEVC hardware decode), capped at
    // the decoder's throughput where it is known.
    NSMutableDictionary *h264 = [@{ @"codec" : @"h264" } mutableCopy];
    NSNumber *budget = LDDecodeBudget();
    if (budget) h264[@"maxPixelsPerSecond"] = budget;

    [self sendControl:@{
        @"type" : @"hello",
        @"pixelsWide" : @(_pixelsWide),
        @"pixelsHigh" : @(_pixelsHigh),
        @"scale" : @(_scale),
        @"device" : _deviceKind,
        @"id" : LDInstallID(),
        @"pv" : @(kProtocolVersion),
        @"displayMaxFrameRate" : @(_maxFrameRate),
        @"videoCaps" : @[ h264 ],
    }
                   on:connection
           completion:nil];
}

- (void)sendControl:(NSDictionary *)message on:(nw_connection_t)connection completion:(void (^)(void))completion {
    NSData *json = connection ? [NSJSONSerialization dataWithJSONObject:message options:0 error:NULL] : nil;
    // §3: receiver-to-sender payloads must be 1 to 2^20 - 1 bytes.
    if (json.length == 0 || json.length >= (1u << 20)) {
        if (completion) completion();
        return;
    }
    uint32_t length = CFSwapInt32HostToBig((uint32_t)json.length);
    NSMutableData *frame = [NSMutableData dataWithBytes:&length length:4];
    [frame appendData:json];
    dispatch_data_t data = dispatch_data_create(frame.bytes, frame.length, _queue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    nw_connection_send(connection, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        if (completion) completion();
    });
}

- (void)requestKeyframe {
    // §5.3. Rate-limited: every undecodable frame until the IDR lands would
    // otherwise ask again.
    CFTimeInterval now = CACurrentMediaTime();
    if (!_connectionReady || now - _lastKeyframeRequest < 0.5) return;
    _lastKeyframeRequest = now;
    _statKeyframeRequests++;
    [self sendControl:@{ @"type" : @"kf" } on:_connection completion:nil];
}

- (void)tick {
    _ticks++;
    if (!_connection || !_connectionReady) return;
    if (CACurrentMediaTime() - _lastReceived > kSilenceTimeout) {
        [self drop:_connection reason:@"silent for 5 s"];
        return;
    }
    if (_ticks % kPingEveryTicks == 0) {
        [self sendControl:@{ @"type" : @"ping", @"t" : @(round(LDNowMs())) } on:_connection completion:nil];
    }
    if (_ticks % kStatsEveryTicks == 0) [self sendStats];
}

- (void)sendStats {
    CFTimeInterval now = CACurrentMediaTime();
    double elapsed = MAX(now - _statStart, 0.001);
    double fps = _statFrames / elapsed;
    double shown = _statEnqueued / elapsed;
    double mbps = _statBytes * 8 / elapsed / 1e6;
    // §6.1 `stats` is free-form; the Mac logs it as PHONE-STATS.
    [self sendControl:@{
        @"type" : @"stats",
        @"client" : @"LegacyDisplay",
        @"transport" : _transport,
        @"fps" : @(round(fps)),
        @"enqueuedFps" : @(round(shown)),
        @"mbps" : @(round(mbps * 10) / 10),
        @"rtt" : @(round(_lastRTT)),
        @"kfRequests" : @(_statKeyframeRequests),
        @"offsetKnown" : @(_offsetKnown),
    }
                   on:_connection
           completion:nil];

    NSString *summary = [NSString stringWithFormat:@"%@  %.0f fps  %.1f Mbps  rtt %.0f ms  kf %lu",
                                                   _transport, fps, mbps, _lastRTT,
                                                   (unsigned long)_statKeyframeRequests];
    _statFrames = _statEnqueued = _statBytes = _statKeyframeRequests = 0;
    _statStart = now;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate receiver:self statsDidUpdate:summary];
    });
}

#pragma mark - Receiving

- (void)receiveOn:(nw_connection_t)connection {
    __weak typeof(self) weakSelf = self;
    nw_connection_receive(connection, 1, 1 << 18,
        ^(dispatch_data_t content, nw_content_context_t context, bool isComplete, nw_error_t error) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || connection != strongSelf->_connection) return;
            if (content) [strongSelf didReceive:content];
            if (connection != strongSelf->_connection) return;
            if (error || isComplete) {
                [strongSelf drop:connection reason:error ? @"receive error" : @"closed by the Mac"];
                return;
            }
            [strongSelf receiveOn:connection];
        });
}

- (void)didReceive:(dispatch_data_t)content {
    _lastReceived = CACurrentMediaTime();
    NSMutableData *buffer = _buffer;
    dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *bytes, size_t size) {
        [buffer appendBytes:bytes length:size];
        return true;
    });
    [self drainFrames];
}

/// §3: [4-byte big-endian length][payload], reassembled across reads.
- (void)drainFrames {
    nw_connection_t connection = _connection;
    const uint8_t *bytes = _buffer.bytes;
    NSUInteger available = _buffer.length;
    NSUInteger cursor = 0;
    while (available - cursor >= 4) {
        const uint8_t *header = bytes + cursor;
        uint32_t length = (uint32_t)header[0] << 24 | (uint32_t)header[1] << 16 | (uint32_t)header[2] << 8 | header[3];
        if (length > kMaxFrameLength) {
            [self drop:connection reason:@"corrupt frame length"];
            return;
        }
        if (available - cursor - 4 < length) break;
        [self handlePayload:header + 4 length:length];
        // Handling can end the session, which empties the buffer under us.
        if (_connection != connection) return;
        cursor += 4 + length;
    }
    if (cursor) [_buffer replaceBytesInRange:NSMakeRange(0, cursor) withBytes:NULL length:0];
}

- (void)handlePayload:(const uint8_t *)payload length:(NSUInteger)length {
    if (length == 0) return;
    // §4 demux heuristic, due to be replaced by a typed header at pv 4. Kept
    // to this one test so that swap stays cheap.
    BOOL isControl = length < 32768 && payload[0] == '{' && memchr(payload, 0, length) == NULL;
    if (isControl) {
        [self handleControl:[NSData dataWithBytesNoCopy:(void *)payload length:length freeWhenDone:NO]];
    } else {
        [self handleVideo:payload length:length];
    }
}

#pragma mark - Control messages (§6.2)

- (void)handleControl:(NSData *)json {
    NSDictionary *message = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    if (![message isKindOfClass:NSDictionary.class]) return;
    NSString *type = message[@"type"];
    if (![type isKindOfClass:NSString.class]) return;

    if ([type isEqualToString:@"cursor"]) {
        [self handleCursor:message];
    } else if ([type isEqualToString:@"pong"]) {
        [self handlePong:message];
    } else if ([type isEqualToString:@"ping"]) {
        // The sender's ping is a liveness beat only; it expects no reply.
    } else if ([type isEqualToString:@"cursorImg"]) {
        [self handleCursorImage:message];
    } else if ([type isEqualToString:@"welcome"]) {
        _senderVersion = (NSInteger)LDNumber(message[@"pv"], 1);
        LDLog(@"welcome: sender pv %ld, min %ld", (long)_senderVersion, (long)LDNumber(message[@"min"], 1));
    } else if ([type isEqualToString:@"streamConfig"]) {
        NSString *codec = message[@"codec"];
        LDLog(@"streamConfig: %@ %.0fx%.0f @%.0f", codec, LDNumber(message[@"width"], 0),
              LDNumber(message[@"height"], 0), LDNumber(message[@"framesPerSecond"], 0));
        if ([codec isKindOfClass:NSString.class] && ![codec isEqualToString:@"h264"]) {
            [self setStatus:[NSString stringWithFormat:@"The Mac chose %@, which this device can't decode", codec]];
        }
    } else if ([type isEqualToString:@"updateRequired"]) {
        NSString *text = [message[@"message"] isKindOfClass:NSString.class]
                             ? message[@"message"]
                             : @"The Mac app says this receiver is too old.";
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate receiver:self updateRequired:text];
        });
    } else if (![_ignoredTypes containsObject:type]) {
        // §6: unknown types must be ignored; log each once.
        [_ignoredTypes addObject:type];
        LDLog(@"ignoring message type %@", type);
    }
}

- (void)handlePong:(NSDictionary *)message {
    // §8.1: NTP-style offset from the minimum-RTT sample of the last 15.
    double t1 = LDNumber(message[@"t"], NAN);
    double mt = LDNumber(message[@"mt"], NAN);
    if (isnan(t1) || isnan(mt)) return;
    double t2 = LDNowMs();
    double rtt = t2 - t1;
    if (rtt < 0 || rtt >= 2000) return;
    _lastRTT = rtt;
    [_clockSamples addObject:@[ @(rtt), @(mt - (t1 + t2) / 2) ]];
    if (_clockSamples.count > 15) [_clockSamples removeObjectAtIndex:0];
    NSArray<NSNumber *> *best = nil;
    for (NSArray<NSNumber *> *sample in _clockSamples) {
        if (!best || sample[0].doubleValue < best[0].doubleValue) best = sample;
    }
    _clockOffset = best[1].doubleValue;
    _offsetKnown = YES;
}

- (void)handleCursor:(NSDictionary *)message {
    // §6.3: drop anything not newer than the last sequence number. A cursor
    // without `s` comes from an older sender and applies unconditionally.
    id sequence = message[@"s"];
    if ([sequence isKindOfClass:NSNumber.class]) {
        long long s = [sequence longLongValue];
        if (s <= _lastCursorSeq) return;
        _lastCursorSeq = s;
    }
    BOOL visible = LDNumber(message[@"v"], 0) == 1;
    if (visible) _cursorPoint = CGPointMake(LDNumber(message[@"x"], _cursorPoint.x), LDNumber(message[@"y"], _cursorPoint.y));
    CGPoint point = _cursorPoint;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate receiver:self cursorMovedTo:point visible:visible];
    });
}

- (void)handleCursorImage:(NSDictionary *)message {
    NSString *base64 = message[@"png"];
    if (![base64 isKindOfClass:NSString.class]) return;
    NSData *png = [[NSData alloc] initWithBase64EncodedString:base64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImage *image = png ? [UIImage imageWithData:png] : nil;
    double nw = LDNumber(message[@"nw"], 0), nh = LDNumber(message[@"nh"], 0);
    if (!image || nw <= 0 || nh <= 0) return;
    CGPoint anchor = CGPointMake(LDNumber(message[@"ax"], 0), LDNumber(message[@"ay"], 0));
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate receiver:self cursorImage:image anchor:anchor size:CGSizeMake(nw, nh)];
    });
}

#pragma mark - Video (§5)

- (void)handleVideo:(const uint8_t *)bytes length:(size_t)length {
    _statFrames++;
    _statBytes += length;

    // §5.1: an optional JSON telemetry prefix, then NALUs each behind a
    // 4-byte start code. Everything before the first start code is skipped.
    LDRange nalus[kMaxNALUs];
    int count = 0;
    size_t start = SIZE_MAX;
    for (size_t i = 0; i + 4 <= length;) {
        if (bytes[i + 2] > 1) {
            i += 3;  // can't be inside a start code that begins at i, i+1 or i+2
        } else if (bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1) {
            if (start != SIZE_MAX && count < kMaxNALUs) nalus[count++] = (LDRange){ start, i - start };
            start = i + 4;
            i += 4;
        } else {
            i++;
        }
    }
    if (start != SIZE_MAX && start < length && count < kMaxNALUs) nalus[count++] = (LDRange){ start, length - start };

    BOOL parametersChanged = NO;
    BOOL keyframe = NO;
    size_t sampleSize = 0;
    for (int n = 0; n < count; n++) {
        const uint8_t *nalu = bytes + nalus[n].start;
        size_t size = nalus[n].length;
        if (size == 0) continue;
        switch (nalu[0] & 0x1F) {
        case 7:  // SPS
            if (_sps.length != size || memcmp(_sps.bytes, nalu, size) != 0) {
                _sps = [NSData dataWithBytes:nalu length:size];
                parametersChanged = YES;
            }
            nalus[n].length = 0;
            break;
        case 8:  // PPS
            if (_pps.length != size || memcmp(_pps.bytes, nalu, size) != 0) {
                _pps = [NSData dataWithBytes:nalu length:size];
                parametersChanged = YES;
            }
            nalus[n].length = 0;
            break;
        case 5:  // IDR slice
            keyframe = YES;
            sampleSize += 4 + size;
            break;
        case 1: case 2: case 3: case 4:  // other slices
            sampleSize += 4 + size;
            break;
        default:  // SEI, AUD and the rest carry nothing the decoder needs here
            nalus[n].length = 0;
            break;
        }
    }

    // §5.2: new parameter sets mean a new stream; rebuild and drop the old format's frames.
    if (parametersChanged && _sps && _pps) [self rebuildFormat];
    if (sampleSize == 0) return;
    if (!_format) {
        [self requestKeyframe];  // joined mid-GOP
        return;
    }
    if (_paused) return;
    if (_displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        LDLog(@"display layer failed (%@), flushing", _displayLayer.error.localizedDescription);
        [_displayLayer flush];
        _awaitingKeyframe = YES;
    }
    if (_awaitingKeyframe) {
        if (!keyframe) {
            [self requestKeyframe];
            return;
        }
        _awaitingKeyframe = NO;
    }

    // One access unit per wire frame (§5.1) becomes one AVCC sample:
    // each slice NALU behind a 4-byte big-endian length instead of a start code.
    CMBlockBufferRef block = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, sampleSize, kCFAllocatorDefault, NULL, 0,
                                           sampleSize, kCMBlockBufferAssureMemoryNowFlag, &block) != kCMBlockBufferNoErr) {
        return;
    }
    char *out = NULL;
    CMBlockBufferGetDataPointer(block, 0, NULL, NULL, &out);
    for (int n = 0; n < count; n++) {
        if (nalus[n].length == 0) continue;
        uint32_t prefix = CFSwapInt32HostToBig((uint32_t)nalus[n].length);
        memcpy(out, &prefix, 4);
        memcpy(out + 4, bytes + nalus[n].start, nalus[n].length);
        out += 4 + nalus[n].length;
    }

    CMSampleBufferRef sample = NULL;
    OSStatus status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, _format, 1, 0, NULL, 1, &sampleSize, &sample);
    CFRelease(block);
    if (status != noErr || !sample) return;
    // No timestamps cross the wire (§5.1): show each frame as it arrives.
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef first = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(first, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }
    [_displayLayer enqueueSampleBuffer:sample];
    CFRelease(sample);
    _statEnqueued++;
}

- (void)rebuildFormat {
    const uint8_t *sets[2] = { _sps.bytes, _pps.bytes };
    size_t sizes[2] = { _sps.length, _pps.length };
    CMVideoFormatDescriptionRef format = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, sets, sizes, 4, &format);
    if (status != noErr || !format) {
        LDLog(@"bad SPS/PPS (%d)", (int)status);
        return;
    }
    if (_format) CFRelease(_format);
    _format = format;
    [_displayLayer flush];
    _awaitingKeyframe = NO;

    CGSize size = CMVideoFormatDescriptionGetPresentationDimensions(format, false, true);
    LDLog(@"stream %.0fx%.0f", size.width, size.height);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate receiver:self videoSizeDidChange:size];
    });
}

#pragma mark - Delegate plumbing

- (void)setStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate receiver:self statusDidChange:status];
    });
}

- (void)setConnected:(BOOL)connected {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate receiver:self connectedDidChange:connected];
    });
}

@end
