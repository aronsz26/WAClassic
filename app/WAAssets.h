#import <UIKit/UIKit.h>

// 2.10 assets only live on the device (Library/WA4S/Assets), bridge downloads them once.
// WAImg draws simple stand-ins for the important ones, nil for the rest
UIImage *WAImg(NSString *name);
// mark_d in blue, 2.10 had no read tick
UIImage *WAReadTick(void);
// sync missing files from the bridge, copy launch image + sounds into the app, build ringtone.
// changed is called when new pics arrived
void WAAssetsSync(void (^changed)(void));
// nil if it's still the empty placeholder
NSString *WABundleFile(NSString *file);
UIImage *WAStretch(NSString *name, CGFloat top, CGFloat left, CGFloat bottom, CGFloat right);
NSString *WAAssetPath(NSString *file);
// system graphic by path, tries @2x~iphone / @2x / ~iphone / plain
UIImage *WASystemImg(NSString *pathWithoutSuffix);
