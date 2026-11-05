#import <UIKit/UIKit.h>

// edit group subject (25 chars)
@interface WASubjectEditController : UITableViewController <UITextFieldDelegate>
- (instancetype)initWithGroup:(NSString *)jid subject:(NSString *)subject;
@property (nonatomic, copy) void (^onSaved)(NSString *subject);
@end
