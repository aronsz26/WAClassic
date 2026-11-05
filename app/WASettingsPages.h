#import <UIKit/UIKit.h>

// settings tab like 2.10
@interface WASettingsRootViewController : UITableViewController
@end

// table from data: sections {header, footer, rows}, rows {title, detail, switch, on/toggle,
// action, disclosure, button, image, subtitle}
@interface WATableController : UITableViewController
@property (nonatomic, copy) NSArray *sections;
- (void)rebuild;
@end

// bubble colors, all chats (jid nil) or one
@interface WABubbleColorsController : WATableController
- (instancetype)initWithJID:(NSString *)jid;
@end
