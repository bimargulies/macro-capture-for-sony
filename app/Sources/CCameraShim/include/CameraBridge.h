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
/// The camera reports the shutter fired and holds the image (it is not on the Mac yet).
- (void)cameraBridgeDidCapture:(CameraBridge *)bridge;
/// The SDK finished transferring a photo into the save folder; `path` is the complete file.
- (void)cameraBridge:(CameraBridge *)bridge didDownloadFile:(NSString *)path;
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

/// Where the SDK writes photos it transfers from the camera. Call after connecting.
- (BOOL)setSaveFolder:(NSString *)path error:(NSError * _Nullable * _Nullable)error;

/// Holds (YES) or releases (NO) the half-press (S1). The camera needs S1 held before a full press will fire.
- (BOOL)setHalfPress:(BOOL)pressed error:(NSError * _Nullable * _Nullable)error;

/// Full press (S2 down, then up). The photo is transferred to the save folder afterwards.
- (BOOL)fullPressWithError:(NSError * _Nullable * _Nullable)error;

/// The magnifier ratio codes the camera accepts, ascending, tenths of a power (47 = x4.7).
/// Excludes "off" and x1.0 (which looks the same as off). Empty if unsupported.
- (NSArray<NSNumber *> *)magnifierRatios;

/// Sets the focus magnifier. `ratio` 0 turns it off. `x`,`y` are the centre in the camera's
/// 640x480 coordinate space (0,0 top-left). Takes effect in the live view within a moment.
- (BOOL)setMagnifierRatio:(uint32_t)ratio x:(int)x y:(int)y error:(NSError * _Nullable * _Nullable)error;

/// Set after connecting if the shim had to change the camera's setting so photos reach the Mac
/// (e.g. it was saving to the memory card only). Nil if nothing was changed.
@property (nonatomic, readonly, nullable) NSString *transferNote;

/// Releases the SDK itself. Call once, at process exit, after `disconnect`. The SDK cannot
/// be initialized again in the same process after this.
- (void)releaseSDK;

@end

NS_ASSUME_NONNULL_END
