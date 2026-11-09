#import <UIKit/UIKit.h>

// first start in the look of the ios 5/6 setup (linen, slide to set up), only for new installs.
// graphics come from the phone's own Setup.app/TelephonyUI, drawn stand-ins where they're missing (ios 4)

UIImage *WALinen(void);

// "WA Classic" title + slider, like the setup lock screen
@interface WAHelloViewController : UIViewController
@property (nonatomic, copy) void (^finished)(void); // after the chats arrived and Start Using
@end

// Automatically Send / Don't Send
@interface WADiagChoiceViewController : UITableViewController
@property (nonatomic, copy) void (^finished)(void);
@end

// last page, after the chats loaded
@interface WAThankYouViewController : UIViewController
@property (nonatomic, copy) void (^finished)(void);
@end
