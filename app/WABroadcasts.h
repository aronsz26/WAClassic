#import <UIKit/UIKit.h>

// 2.10 broadcasts: list of sent ones + detail page with recipients/ticks, rebroadcast
@interface WABroadcastListViewController : UITableViewController
// list if there are some, else new broadcast
+ (void)openFrom:(UIViewController *)from;
@end

@interface WABroadcastViewController : UITableViewController <UIActionSheetDelegate>
- (instancetype)initWithBroadcast:(NSDictionary *)broadcast;
@end
