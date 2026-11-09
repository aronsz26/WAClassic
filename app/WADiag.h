#import <UIKit/UIKit.h>

// diagnostics, only after the user said yes (asked once). once a day to update.waclassic.com/t:
// iphone model, ios, app and bridge version, bridge platform, language, setup bits, crash reports, error codes.
// since 1.0.3 also: notification delay and connection counts in steps, upload size steps,
// memory warnings, start time, known tls/store tweaks, the bridge's error counts.
// never messages, contacts, numbers, names or how much someone uses the app
extern NSString *const WAPrefDiagnostics;
extern NSString *const WADiagWhat; // what gets sent, for the alert and settings

@interface WADiag : NSObject
@property (nonatomic, readonly) BOOL asking;
+ (instancetype)shared;
- (void)askIfNeeded;
- (void)sendIfDue;
- (void)noteBridge:(NSDictionary *)status;
- (void)record:(NSString *)code;
@property (nonatomic, readonly) BOOL extended; // sends the 1.0.3 list (every yes, 1.0.2 ones too)
- (void)count:(NSString *)code; // only with consent 2
- (void)noteDelay:(NSTimeInterval)secs of:(NSString *)what; // "notify <1m" etc.
- (void)noteLaunched;
- (void)turnedOff; // removes what was sent
- (void)turnedOn; // from settings, agrees to the current list
- (void)chosenInSetup:(BOOL)send; // new installs, nothing is sent before the bridge is there
@end
