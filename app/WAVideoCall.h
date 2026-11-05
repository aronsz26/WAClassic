#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

// new peer frame, userInfo "image" (rotate by orientation)
extern NSString *const WAVideoPictureNotification;

// old ios can't encode h264 for apps, so we send jpegs and the bridge does h264 with ffmpeg.
// socket /api/call/video: 4 byte BE length + jpeg, both ways
// frames stay landscape, /api/call/orientation tells the peer
@interface WAVideoCall : NSObject

+ (WAVideoCall *)shared;

// nil while off
@property (nonatomic, readonly) AVCaptureSession *session;
@property (nonatomic, readonly) BOOL frontCamera;
@property (nonatomic, readonly) BOOL canSwitchCamera;
- (void)switchCamera;

- (void)update;

@end
