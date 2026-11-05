#import <UIKit/UIKit.h>

// favorites tab like 2.10, starts empty, stored on the device only
@interface WAFavoritesViewController : UITableViewController <UISearchBarDelegate, UIActionSheetDelegate>
+ (BOOL)isFavorite:(NSString *)jid;
+ (void)setFavorite:(NSString *)jid on:(BOOL)on;
@end
