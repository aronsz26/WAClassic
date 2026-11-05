#import <UIKit/UIKit.h>

// new group like 2.10: participants as tokens, subject (25), optional icon
@interface WANewGroupViewController : UIViewController
// same composer for broadcasts (max 50)
@property (nonatomic) BOOL broadcast;
@property (nonatomic, copy) void (^onBroadcastSent)(NSDictionary *broadcast);
@end

// contact picker with checkmarks
@interface WAPeoplePickerController : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) NSArray *contacts;
@property (nonatomic, strong) NSMutableSet *selected;
@property (nonatomic, copy) void (^onDone)(NSSet *selected);
@end
