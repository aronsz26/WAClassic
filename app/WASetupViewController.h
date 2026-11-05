#import <UIKit/UIKit.h>

// bridge got unlinked -> show setup again
extern NSString *const WALinkNeededNotification;

// first start like 2.10 registration, but with a qr code instead of the phone number
@interface WASetupViewController : UIViewController
@property (nonatomic, copy) void (^finished)(void);
@end

// welcome page (2.10 PaymentEdu look)
@interface WAWelcomeViewController : UIViewController
@property (nonatomic, copy) void (^finished)(void);
@end

// short list after welcome: how it works, where to get help
@interface WAHowItWorksViewController : UIViewController
@property (nonatomic, copy) void (^finished)(void);
@end

// after the qr code, until the chats are there
@interface WALoadingChatsViewController : UIViewController
@property (nonatomic, copy) void (^finished)(void);
@end

// bridge address + setup code
@interface WAConnectViewController : UITableViewController <UITextFieldDelegate>
@property (nonatomic, copy) void (^finished)(void);
@end
