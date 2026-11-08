#import <UIKit/UIKit.h>

// calls tab, dev builds only for now. takes the place of status
// recent calls from /api/calls (bridge), hidden rows are this iphone only
@interface WACallsViewController : UITableViewController <UIActionSheetDelegate>
// notifypost test hooks: missed, all, new, edit
- (void)devCommand:(NSString *)what;
@end
