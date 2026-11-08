#import <UIKit/UIKit.h>

// asks update.waclassic.com/latest.json every few hours if there's a newer WA Classic.
// open app: alert with Later / Open Cydia. in the background: one notification per version
@interface WAUpdate : NSObject
+ (instancetype)shared;
- (void)checkActive:(BOOL)active;
@end
