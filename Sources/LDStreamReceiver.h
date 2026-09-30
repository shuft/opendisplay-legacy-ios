#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

@class LDStreamReceiver;

/// Every callback arrives on the main queue.
@protocol LDStreamReceiverDelegate <NSObject>
- (void)receiver:(LDStreamReceiver *)receiver statusDidChange:(NSString *)status;
- (void)receiver:(LDStreamReceiver *)receiver connectedDidChange:(BOOL)connected;
/// Decoded video size in pixels, taken from the SPS.
- (void)receiver:(LDStreamReceiver *)receiver videoSizeDidChange:(CGSize)size;
/// `point` is normalized 0..1 in video space, origin top-left.
- (void)receiver:(LDStreamReceiver *)receiver cursorMovedTo:(CGPoint)point visible:(BOOL)visible;
/// `anchor` is the hotspot within the sprite (0..1); `size` is the sprite size normalized to the display.
- (void)receiver:(LDStreamReceiver *)receiver cursorImage:(UIImage *)image anchor:(CGPoint)anchor size:(CGSize)size;
- (void)receiver:(LDStreamReceiver *)receiver updateRequired:(NSString *)message;
- (void)receiver:(LDStreamReceiver *)receiver statsDidUpdate:(NSString *)summary;
@end

/// Receiver end of the OpenDisplay wire protocol (pv 3): listens on TCP 9000,
/// advertises itself over Bonjour, and decodes the H.264 stream into a display
/// layer. The Mac dials in over Wi-Fi or through usbmuxd over the cable; both
/// look like an ordinary inbound connection here.
@interface LDStreamReceiver : NSObject

@property (nonatomic, weak) id<LDStreamReceiverDelegate> delegate;

- (instancetype)initWithDisplayLayer:(AVSampleBufferDisplayLayer *)displayLayer NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Physical panel pixels in the current orientation. Re-sends hello on a live
/// session when they change, which is how rotation reaches the Mac.
- (void)setPanelPixelsWide:(NSInteger)wide high:(NSInteger)high scale:(double)scale;

- (void)start;

/// App became active: re-arm the listener if suspension or sleep took it down,
/// and resync the picture.
- (void)resume;
/// App went to the background: stop feeding the decoder (hardware decode fails off-screen).
- (void)pause;
/// Device is locking: tell the Mac and go quiet until resume.
- (void)enterSleep;
/// App is terminating: tell the Mac the session is over. Blocks up to `timeout`.
- (void)shutDownWaitingUpTo:(NSTimeInterval)timeout;

/// x/y normalized 0..1 in video space. Phase is began, moved, ended or cancelled.
- (void)sendTouchPhase:(NSString *)phase x:(double)x y:(double)y;
/// Deltas in video pixels, natural-scrolling sign.
- (void)sendScrollDx:(double)dx dy:(double)dy;

@end
