#import <UIKit/UIKit.h>

// dev builds only (DEV=1 tools/build-app.sh), the normal package has none of this

// corner label + notifypost commands, call once after the main window is up
void WADevStart(UIWindow *mainWindow);
// "1.0 (241+)"
NSString *WADevVersion(void);
UIViewController *WADevMenu(void);
// calls, or status if the debug switch says so
UIViewController *WADevSecondTab(void);
// from WAConnection
void WADevCountRequest(NSUInteger bytesIn, NSUInteger bytesOut, BOOL failed);

typedef struct {
	unsigned long long requests, failed, bytesIn, bytesOut;
	unsigned long long polls, messages, serverSwitches, networkChanges;
	NSTimeInterval lastUpdate, started;
} WADevCounters;
extern WADevCounters WADevCount;

// pages, WADevTests.m / WADevStats.m
UIViewController *WADevTestsPage(BOOL runNow);
UIViewController *WADevStatsPage(void);
UIViewController *WADevManualPage(void);
void WADevManualPress(UIViewController *page, NSString *what);
UIViewController *WADevLogPage(void);
void WADevDumpStats(void);

#define WADevFolder @"/var/mobile/Library/WA4S"
