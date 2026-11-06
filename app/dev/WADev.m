#import <QuartzCore/QuartzCore.h>
#import "WADev.h"
#import "../WAClient.h"
#import "../WASettingsPages.h"
#import "../WAPrefs.h"
#import "../WAUtil.h"

WADevCounters WADevCount;

NSString *WADevVersion(void) {
	NSString *v = [NSBundle mainBundle].infoDictionary[@"CFBundleVersion"];
	return [NSString stringWithFormat:@"%@ (%s)", v, WA_DEV_BUILD];
}

void WADevCountRequest(NSUInteger bytesIn, NSUInteger bytesOut, BOOL failed) {
	WADevCount.requests++;
	WADevCount.bytesIn += bytesIn;
	WADevCount.bytesOut += bytesOut;
	if (failed) WADevCount.failed++;
}

#pragma mark - Corner label

static UIWindow *mainWindow, *corner;

// above the tab bar when there is one, it would cover "Settings" otherwise
static BOOL TabBarShowing(void) {
	UITabBarController *tabs = (UITabBarController *)mainWindow.rootViewController;
	if (![tabs isKindOfClass:[UITabBarController class]] || tabs.presentedViewController) return NO;
	UITabBar *bar = tabs.tabBar;
	if (!bar.window || bar.hidden) return NO;
	CGRect r = [bar convertRect:bar.bounds toView:nil];
	return CGRectGetMaxY(r) <= mainWindow.bounds.size.height + 0.5;
}

static void PlaceCorner(void) {
	CGSize screen = [UIScreen mainScreen].bounds.size, size = corner.frame.size;
	CGFloat bottom = TabBarShowing() ? 49 + 2 : 1;
	CGRect frame = CGRectMake(screen.width - size.width - 1, screen.height - size.height - bottom, size.width, size.height);
	if (!CGRectEqualToRect(frame, corner.frame)) corner.frame = frame;
}

@interface WADevTicker : NSObject
@end

@implementation WADevTicker
+ (void)tick {
	PlaceCorner();
}
@end

static void ShowCorner(void) {
	UILabel *label = [[UILabel alloc] init];
	label.text = [@"internal version " stringByAppendingString:WADevVersion()];
	label.font = [UIFont boldSystemFontOfSize:9];
	label.textColor = [UIColor whiteColor];
	label.backgroundColor = [UIColor clearColor];
	label.textAlignment = NSTextAlignmentCenter;
	[label sizeToFit];
	CGSize size = CGSizeMake(ceil(label.bounds.size.width) + 8, 12);
	label.frame = CGRectMake(0, 0, size.width, size.height);
	// own little window: over alerts and modals, and touches pass by it
	corner = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, size.width, size.height)];
	corner.windowLevel = UIWindowLevelAlert + 1000;
	corner.userInteractionEnabled = NO;
	corner.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
	corner.layer.cornerRadius = 3;
	[corner addSubview:label];
	corner.hidden = NO;
	PlaceCorner();
	NSTimer *timer = [NSTimer timerWithTimeInterval:0.5 target:[WADevTicker class] selector:@selector(tick) userInfo:nil repeats:YES];
	[[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

#pragma mark - Menu

@interface WADevMenuController : WATableController
@end

@implementation WADevMenuController

- (instancetype)init {
	if ((self = [super init])) self.title = @"Debug";
	return self;
}

- (void)rebuild {
	__weak WADevMenuController *weak = self;
	void (^open)(UIViewController *) = ^(UIViewController *page) {
		[weak.navigationController pushViewController:page animated:YES];
	};
	self.sections = @[
		@{@"header": @"Build", @"rows": @[
			@{@"title": @"Internal Version", @"detail": WADevVersion()},
			@{@"title": @"Built", @"detail": @WA_DEV_DATE},
		]},
		@{@"header": @"Debug", @"rows": @[
			@{@"title": @"Self Tests", @"disclosure": @YES, @"action": ^{ open(WADevTestsPage(NO)); }},
			@{@"title": @"Stats", @"disclosure": @YES, @"action": ^{ open(WADevStatsPage()); }},
			@{@"title": @"Manual Tests", @"disclosure": @YES, @"action": ^{ open(WADevManualPage()); }},
			@{@"title": @"Log", @"disclosure": @YES, @"action": ^{ open(WADevLogPage()); }},
		]},
		@{@"header": @"Switches", @"footer": @"Video calls are hidden in the normal app.", @"rows": @[
			@{@"title": @"Video Calls", @"switch": WAPrefVideoCalls},
		]},
	];
}

@end

UIViewController *WADevMenu(void) {
	return [[WADevMenuController alloc] init];
}

#pragma mark - Commands

// no tapping over ssh: notifypost com.aronsz26.wa4s.dev.<what>, list in WADevStart
static UINavigationController *commandNav;
static UIViewController *commandManual;

@interface WADevCloser : NSObject
@end

@implementation WADevCloser
+ (void)close {
	[commandNav dismissViewControllerAnimated:YES completion:nil];
	commandNav = nil;
}
@end

static void Show(UIViewController *page) {
	NSMutableArray *stack = [NSMutableArray arrayWithObject:WADevMenu()];
	if (page) [stack addObject:page];
	[stack[0] navigationItem].leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
		target:[WADevCloser class] action:@selector(close)];
	if (commandNav) {
		commandNav.viewControllers = stack;
		return;
	}
	commandNav = [[UINavigationController alloc] init];
	commandNav.viewControllers = stack;
	UIViewController *top = mainWindow.rootViewController;
	while (top.presentedViewController) top = top.presentedViewController;
	[top presentViewController:commandNav animated:NO completion:nil];
}

static void Command(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
	NSString *what = [(__bridge NSString *)name pathExtension];
	WALog(@"dev: command %@", what);
	if ([what isEqualToString:@"menu"]) Show(nil);
	else if ([what isEqualToString:@"tests"]) Show(WADevTestsPage(YES));
	else if ([@[@"message", @"clear", @"ring", @"hangup", @"banner"] containsObject:what]) {
		if (!commandManual) commandManual = WADevManualPage();
		Show(commandManual);
		WADevManualPress(commandManual, what);
	}
	else if ([what isEqualToString:@"manual"]) {
		if (!commandManual) commandManual = WADevManualPage();
		Show(commandManual);
	}
	else if ([what isEqualToString:@"log"]) Show(WADevLogPage());
	else if ([what isEqualToString:@"close"]) [WADevCloser close];
	else if ([what isEqualToString:@"stats"]) {
		Show(WADevStatsPage());
		// after a ping or two
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ WADevDumpStats(); });
	}
}

void WADevStart(UIWindow *window) {
	mainWindow = window;
	WADevCount.started = [NSDate timeIntervalSinceReferenceDate];
	WALog(@"dev: internal version %@, commit %s", WADevVersion(), WA_DEV_COMMIT);
	ShowCorner();
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc addObserverForName:WAClientUpdatesNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
		WADevCount.polls++;
		WADevCount.messages += [note.userInfo[@"messages"] count];
		WADevCount.lastUpdate = [NSDate timeIntervalSinceReferenceDate];
	}];
	[nc addObserverForName:WAClientServerChangedNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
		WADevCount.serverSwitches++;
	}];
	[nc addObserverForName:WAClientNetworkChangedNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
		WADevCount.networkChanges++;
	}];
	for (NSString *what in @[@"menu", @"tests", @"stats", @"manual", @"log", @"close", @"message", @"clear", @"ring", @"hangup", @"banner"]) {
		NSString *name = [@"com.aronsz26.wa4s.dev." stringByAppendingString:what];
		CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, Command, (__bridge CFStringRef)name, NULL,
			CFNotificationSuspensionBehaviorDeliverImmediately);
	}
}
