#import <UIKit/UIKit.h>

// 2.10 SinglePersonPicker, used for "New Message"
@interface WAPersonPicker : UITableViewController <UISearchBarDelegate>
@property (nonatomic, copy) void (^onPick)(NSDictionary *contact);
@end
