#import <UIKit/UIKit.h>

// 2.10 tooltip box with arrow + close button
@interface WATooltip : UIView
// arrow tip at point
+ (WATooltip *)showText:(NSString *)text pointingAt:(CGPoint)point inView:(UIView *)view;
- (void)dismiss;
@property (nonatomic, copy) void (^onClose)(void);
@end
