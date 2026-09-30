#import "LDReceiverViewController.h"
#import "LDStreamReceiver.h"

@interface LDVideoView : UIView
@property (nonatomic, readonly) AVSampleBufferDisplayLayer *displayLayer;
@end

@implementation LDVideoView

+ (Class)layerClass {
    return AVSampleBufferDisplayLayer.class;
}

- (AVSampleBufferDisplayLayer *)displayLayer {
    return (AVSampleBufferDisplayLayer *)self.layer;
}

@end

@interface LDReceiverViewController () <LDStreamReceiverDelegate>
@end

@implementation LDReceiverViewController {
    LDVideoView *_videoView;
    UILabel *_statusLabel;
    UILabel *_statsLabel;
    CALayer *_cursorLayer;
    LDStreamReceiver *_receiver;
    BOOL _started;
    BOOL _updateRequired;

    CGSize _videoSize;
    CGPoint _cursorPoint;
    CGSize _cursorSize;
    BOOL _cursorVisible;

    UITouch *_pointerTouch;
    BOOL _multiFingerGesture;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

// The Mac's Dock and menu bar sit at the screen edges; without this, a touch
// there opens Control Center or the iOS Dock instead.
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return UIRectEdgeAll;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.view.multipleTouchEnabled = YES;

    _videoView = [[LDVideoView alloc] initWithFrame:self.view.bounds];
    _videoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _videoView.userInteractionEnabled = NO;
    [self.view addSubview:_videoView];

    // The cursor rides the control channel at input rate, not baked into the
    // video, so it's drawn here on top of the picture.
    _cursorLayer = [CALayer layer];
    _cursorLayer.hidden = YES;
    _cursorLayer.zPosition = 10;
    _cursorLayer.actions = @{
        @"position" : NSNull.null, @"bounds" : NSNull.null, @"contents" : NSNull.null,
        @"hidden" : NSNull.null, @"anchorPoint" : NSNull.null
    };
    [_videoView.layer addSublayer:_cursorLayer];

    _statusLabel = [UILabel new];
    _statusLabel.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    _statusLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 0;
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_statusLabel];

    _statsLabel = [UILabel new];
    _statsLabel.textColor = UIColor.greenColor;
    _statsLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    _statsLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    _statsLabel.hidden = YES;
    _statsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_statsLabel];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_statusLabel.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [_statusLabel.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [_statusLabel.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor multiplier:0.8],
        [_statsLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [_statsLabel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
    ]];

    // Two-finger pan scrolls, like a trackpad. It doesn't cancel touches:
    // the touch handlers below withdraw the press themselves.
    UIPanGestureRecognizer *scroll = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleScroll:)];
    scroll.minimumNumberOfTouches = 2;
    scroll.maximumNumberOfTouches = 2;
    scroll.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:scroll];

    // Three-finger tap toggles the stats overlay.
    UITapGestureRecognizer *stats = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleStats)];
    stats.numberOfTouchesRequired = 3;
    stats.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:stats];

    _receiver = [[LDStreamReceiver alloc] initWithDisplayLayer:_videoView.displayLayer];
    _receiver.delegate = self;
    [self showStatus:@"Starting"];

    UIApplication.sharedApplication.idleTimerDisabled = YES;

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(didBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(didEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    // Locking (not a plain app switch) makes protected data unavailable. It
    // only fires with a passcode set; without one, the Mac notices the
    // silence instead.
    [center addObserver:self selector:@selector(willLock) name:UIApplicationProtectedDataWillBecomeUnavailable object:nil];
    [center addObserver:self selector:@selector(willTerminate) name:UIApplicationWillTerminateNotification object:nil];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self announcePanel];
    [self layoutCursor];
}

/// §6.1 hello: physical pixels in the current orientation.
- (void)announcePanel {
    UIScreen *screen = UIScreen.mainScreen;
    CGSize native = screen.nativeBounds.size;  // always portrait
    CGFloat longSide = MAX(native.width, native.height), shortSide = MIN(native.width, native.height);
    BOOL landscape = screen.bounds.size.width > screen.bounds.size.height;
    [_receiver setPanelPixelsWide:(NSInteger)(landscape ? longSide : shortSide)
                             high:(NSInteger)(landscape ? shortSide : longSide)
                            scale:screen.scale];
    if (!_started) {
        _started = YES;
        [_receiver start];
    }
}

#pragma mark - Lifecycle

- (void)didBecomeActive {
    [_receiver resume];
}

- (void)didEnterBackground {
    [_receiver pause];
}

- (void)willLock {
    [_receiver enterSleep];
}

- (void)willTerminate {
    [_receiver shutDownWaitingUpTo:1.0];
}

#pragma mark - Geometry

/// Where the video actually sits inside the view under aspect-fit.
- (CGRect)videoRect {
    CGRect bounds = _videoView.bounds;
    if (_videoSize.width <= 0 || _videoSize.height <= 0 || CGRectIsEmpty(bounds)) return bounds;
    CGFloat videoAspect = _videoSize.width / _videoSize.height;
    if (videoAspect > bounds.size.width / bounds.size.height) {
        CGFloat height = bounds.size.width / videoAspect;
        return CGRectMake(0, (bounds.size.height - height) / 2, bounds.size.width, height);
    }
    CGFloat width = bounds.size.height * videoAspect;
    return CGRectMake((bounds.size.width - width) / 2, 0, width, bounds.size.height);
}

- (void)layoutCursor {
    CGRect rect = [self videoRect];
    if (_cursorSize.width <= 0 || CGRectIsEmpty(rect)) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _cursorLayer.bounds = CGRectMake(0, 0, _cursorSize.width * rect.size.width, _cursorSize.height * rect.size.height);
    _cursorLayer.position = CGPointMake(CGRectGetMinX(rect) + _cursorPoint.x * rect.size.width,
                                        CGRectGetMinY(rect) + _cursorPoint.y * rect.size.height);
    [CATransaction commit];
}

#pragma mark - Input

// One finger is the pointer: down, drag, up, like a touchscreen. When a
// second finger lands it's a scroll, not a press, so the press is withdrawn
// with `cancelled`, which the Mac releases without a click.

- (NSUInteger)fingersDownIn:(UIEvent *)event {
    NSUInteger down = 0;
    for (UITouch *touch in event.allTouches) {
        if (touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled) down++;
    }
    return down;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([self fingersDownIn:event] > 1) {
        if (_pointerTouch) [self forwardTouch:_pointerTouch phase:@"cancelled"];
        _pointerTouch = nil;
        _multiFingerGesture = YES;
    } else if (!_pointerTouch && !_multiFingerGesture) {
        _pointerTouch = touches.anyObject;
        [self forwardTouch:_pointerTouch phase:@"began"];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_pointerTouch && [touches containsObject:_pointerTouch]) [self forwardTouch:_pointerTouch phase:@"moved"];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self finishTouches:touches event:event phase:@"ended"];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self finishTouches:touches event:event phase:@"cancelled"];
}

- (void)finishTouches:(NSSet<UITouch *> *)touches event:(UIEvent *)event phase:(NSString *)phase {
    if (_pointerTouch && [touches containsObject:_pointerTouch]) {
        [self forwardTouch:_pointerTouch phase:phase];
        _pointerTouch = nil;
    }
    if ([self fingersDownIn:event] == 0) _multiFingerGesture = NO;
}

/// §7: touch x/y are normalized to the video, clamped to its edges.
- (void)forwardTouch:(UITouch *)touch phase:(NSString *)phase {
    CGRect rect = [self videoRect];
    if (CGRectIsEmpty(rect)) return;
    CGPoint point = [touch locationInView:_videoView];
    double x = (MIN(MAX(point.x, CGRectGetMinX(rect)), CGRectGetMaxX(rect)) - CGRectGetMinX(rect)) / rect.size.width;
    double y = (MIN(MAX(point.y, CGRectGetMinY(rect)), CGRectGetMaxY(rect)) - CGRectGetMinY(rect)) / rect.size.height;
    [_receiver sendTouchPhase:phase x:x y:y];
}

/// §7: scroll deltas are in video pixels, natural sign (content follows fingers).
- (void)handleScroll:(UIPanGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateChanged) return;
    CGPoint translation = [gesture translationInView:self.view];
    [gesture setTranslation:CGPointZero inView:self.view];
    CGRect rect = [self videoRect];
    double pixelsPerPoint = (_videoSize.width > 0 && rect.size.width > 0) ? _videoSize.width / rect.size.width
                                                                          : UIScreen.mainScreen.scale;
    [_receiver sendScrollDx:translation.x * pixelsPerPoint dy:translation.y * pixelsPerPoint];
}

- (void)toggleStats {
    _statsLabel.hidden = !_statsLabel.hidden;
}

#pragma mark - Status

- (void)showStatus:(NSString *)status {
    if (_updateRequired) return;
    _statusLabel.text = [NSString stringWithFormat:@"%@\n\nOpen OpenDisplay on your Mac, then plug in the cable or join the same Wi-Fi.", status];
}

#pragma mark - LDStreamReceiverDelegate

- (void)receiver:(LDStreamReceiver *)receiver statusDidChange:(NSString *)status {
    [self showStatus:status];
}

- (void)receiver:(LDStreamReceiver *)receiver connectedDidChange:(BOOL)connected {
    _statusLabel.hidden = connected && !_updateRequired;
    if (!connected) {
        _cursorLayer.hidden = YES;
        _statsLabel.text = nil;
    }
}

- (void)receiver:(LDStreamReceiver *)receiver videoSizeDidChange:(CGSize)size {
    _videoSize = size;
    [self layoutCursor];
}

- (void)receiver:(LDStreamReceiver *)receiver cursorMovedTo:(CGPoint)point visible:(BOOL)visible {
    _cursorPoint = point;
    _cursorVisible = visible;
    _cursorLayer.hidden = !visible || !_cursorLayer.contents;
    [self layoutCursor];
}

- (void)receiver:(LDStreamReceiver *)receiver cursorImage:(UIImage *)image anchor:(CGPoint)anchor size:(CGSize)size {
    _cursorLayer.contents = (__bridge id)image.CGImage;
    _cursorLayer.anchorPoint = anchor;
    _cursorSize = size;
    _cursorLayer.hidden = !_cursorVisible;
    [self layoutCursor];
}

- (void)receiver:(LDStreamReceiver *)receiver updateRequired:(NSString *)message {
    _updateRequired = YES;
    _statusLabel.text = message;
    _statusLabel.hidden = NO;
}

- (void)receiver:(LDStreamReceiver *)receiver statsDidUpdate:(NSString *)summary {
    _statsLabel.text = [NSString stringWithFormat:@" %@ ", summary];
}

@end
