#import <UIKit/UIKit.h>

// diagnostics, only after the user said yes (asked once). once a day to update.waclassic.com/t:
// iphone model, ios, app and bridge version, bridge platform, language, setup bits, crash reports, error codes.
// never messages, contacts, numbers, names or how much someone uses the app
extern NSString *const WAPrefDiagnostics;

@interface WADiag : NSObject
@property (nonatomic, readonly) BOOL asking;
+ (instancetype)shared;
- (void)askIfNeeded;
- (void)sendIfDue;
- (void)noteBridge:(NSDictionary *)status;
- (void)record:(NSString *)code;
- (void)turnedOff; // removes what was sent
@end
