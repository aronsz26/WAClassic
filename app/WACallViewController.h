#import <UIKit/UIKit.h>

// own call screen in ios 6 phone style (used without the tweak)
@interface WACallViewController : UIViewController
+ (void)showIfNeededInWindow:(UIWindow *)window;
+ (BOOL)showing;
@end
