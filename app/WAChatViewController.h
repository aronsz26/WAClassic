#import <UIKit/UIKit.h>

@interface WAChatViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate,
	UIActionSheetDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate>
- (instancetype)initWithChat:(NSDictionary *)chat;
@property (nonatomic, readonly) NSString *jid;
@end
