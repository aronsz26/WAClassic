#import <UIKit/UIKit.h>

// all media grid, newest first
@interface WAMediaViewController : UIViewController
- (instancetype)initWithChat:(NSString *)jid title:(NSString *)title;
@end

// fullscreen photo / video player
@interface WAMediaViewer : NSObject
+ (void)showImageRequest:(NSURLRequest *)request placeholder:(UIImage *)placeholder from:(UIViewController *)vc;
+ (void)playVideoSeq:(long long)seq from:(UIViewController *)vc;
@end
