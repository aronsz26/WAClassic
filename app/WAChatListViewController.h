#import <UIKit/UIKit.h>

@interface WAChatListViewController : UITableViewController <UIActionSheetDelegate, UISearchBarDelegate>
- (void)reload;
- (instancetype)initForChoosingChat;
@property (nonatomic, copy) void (^onChooseChat)(NSDictionary *chat);
@end
