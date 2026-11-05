#import <UIKit/UIKit.h>

// video call ui, facetime style
@interface WAVideoCallViewController : UIViewController
+ (void)showIfNeededInWindow:(UIWindow *)window;
+ (BOOL)wanted;
@end
