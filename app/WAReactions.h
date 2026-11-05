#import <UIKit/UIKit.h>

// quick reactions bubble over the chat, + opens the emoji keyboard
@interface WAReactBar : UIView
+ (void)showForMessage:(NSDictionary *)message chat:(NSString *)jid bubble:(CGRect)bubble inView:(UIView *)view;
@end

// reactions list, own one can be removed
@interface WAReactionsViewController : UITableViewController
- (instancetype)initWithChat:(NSString *)jid message:(NSDictionary *)message;
@end

UIViewController *WAModal(UIViewController *vc, BOOL black);
