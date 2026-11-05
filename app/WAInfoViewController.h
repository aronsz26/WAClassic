#import <UIKit/UIKit.h>

// contact / group info like 2.10
@interface WAInfoViewController : UITableViewController <UIActionSheetDelegate>
- (instancetype)initWithJID:(NSString *)jid name:(NSString *)name group:(BOOL)group;
@end
