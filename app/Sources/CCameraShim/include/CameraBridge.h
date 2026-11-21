// Objective-C interface to the Sony Camera Remote SDK. No C++ in this header,
// so Swift can import it directly. Implementation is in CameraBridge.mm.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class CameraBridge;

typedef NS_ENUM(NSInteger, CameraBridgeState) {
    CameraBridgeStateConnected,
    /// The SDK lost the camera (e.g. powered off) and is trying to reconnect by itself.
    CameraBridgeStateReconnecting,
    /// The SDK gave up or reported an error; the owner should tear down and reconnect.
    CameraBridgeStateDisconnected,
};

@protocol CameraBridgeDelegate <NSObject>
/// Called on the SDK polling thread for each NEW live-view frame (duplicates dropped).
/// `arrivalNanos` is CLOCK_UPTIME_RAW in nanoseconds, taken when the frame was fetched.
- (void)cameraBridge:(CameraBridge *)bridge didReceiveFrame:(NSData *)jpeg arrivalNanos:(uint64_t)arrivalNanos;
/// Called on an arbitrary (SDK) thread when the connection state changes.
- (void)cameraBridge:(CameraBridge *)bridge didChangeState:(CameraBridgeState)state message:(NSString *)message;
@end

@interface CameraBridge : NSObject

@property (nonatomic, weak, nullable) id<CameraBridgeDelegate> delegate;
@property (nonatomic, readonly, nullable) NSString *modelName;
@property (nonatomic, readonly) BOOL isConnected;

/// Blocking: initializes the SDK, finds the first camera, connects, and starts the
/// live-view polling thread. Call from a background queue.
- (BOOL)connectWithError:(NSError * _Nullable * _Nullable)error;

/// Stops polling, disconnects, and releases the SDK. Safe to call more than once.
/// MUST be called before the process exits, or the camera keeps a stale session.
- (void)disconnect;

/// Releases the SDK itself. Call once, at process exit, after `disconnect`. The SDK cannot
/// be initialized again in the same process after this.
- (void)releaseSDK;

@end

NS_ASSUME_NONNULL_END
