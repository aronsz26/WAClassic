#import <QuartzCore/QuartzCore.h>
#import "WADev.h"
#import "../WAHello.h"
#import "../WASetupViewController.h"
#import "WACallsViewController.h"
#import "../WAClient.h"
#import "../WASettingsPages.h"
#import "../WAStatusViewController.h"
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

#pragma mark - Second tab

static NSString *const kStatusTabKey = @"devStatusTab";

static BOOL StatusTabOn(void) {
	return [[NSUserDefaults standardUserDefaults] boolForKey:kStatusTabKey];
}

UIViewController *WADevSecondTab(void) {
	if (StatusTabOn()) return [[WAStatusViewController alloc] init];
	return [[WACallsViewController alloc] init];
}

// swap it live, the other tabs stay as they are
static void SetStatusTab(BOOL on) {
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	[d setBool:on forKey:kStatusTabKey];
	[d synchronize];
	UITabBarController *tabs = (UITabBarController *)mainWindow.rootViewController;
	UIViewController *root = WADevSecondTab();
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
	nav.tabBarItem = root.tabBarItem;
	NSMutableArray *list = [tabs.viewControllers mutableCopy];
	list[1] = nav;
	tabs.viewControllers = list;
	WALog(@"dev: second tab is %@", on ? @"status" : @"calls");
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
		@{@"header": @"Switches", @"footer": @"Video calls are hidden in the normal app. Status Tab shows Status again instead of Calls.", @"rows": @[
			@{@"title": @"Video Calls", @"switch": WAPrefVideoCalls},
			@{@"title": @"Status Tab", @"on": ^BOOL{ return StatusTabOn(); }, @"toggle": ^(BOOL on){ SetStatusTab(on); }},
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

// calls = open the tab, callsmissed/callsall/callsnew/callsedit = do that there
static void CallsCommand(NSString *what) {
	UITabBarController *tabs = (UITabBarController *)mainWindow.rootViewController;
	tabs.selectedIndex = 1;
	UINavigationController *nav = tabs.viewControllers[1];
	[nav popToRootViewControllerAnimated:NO];
	WACallsViewController *calls = (WACallsViewController *)nav.viewControllers[0];
	// status tab switched back on
	if (what.length > 5 && [calls isKindOfClass:[WACallsViewController class]]) [calls devCommand:[what substringFromIndex:5]];
}

// setup pages without unlinking: hello (whole new flow, Done = close), hellodiag, hellothanks, helloterms
static void HelloCommand(NSString *what) {
	// not animated, presenting from a page that's still going away crashes
	[commandNav dismissViewControllerAnimated:NO completion:nil];
	commandNav = nil;
	UIViewController *page;
	if ([what isEqualToString:@"hellodiag"]) page = [[WADiagChoiceViewController alloc] init];
	else if ([what isEqualToString:@"hellothanks"]) page = [[WAThankYouViewController alloc] init];
	else if ([what isEqualToString:@"helloconnect"]) {
		WAConnectViewController *c = [[WAConnectViewController alloc] init];
		c.ios5Style = YES;
		page = c;
	} else if ([what isEqualToString:@"helloqr"]) {
		WASetupViewController *q = [[WASetupViewController alloc] init];
		q.ios5Style = YES;
		page = q;
	} else if ([what isEqualToString:@"helloloading"]) {
		WALoadingChatsViewController *l = [[WALoadingChatsViewController alloc] init];
		l.ios5Style = YES;
		page = l;
	} else if ([what isEqualToString:@"helloterms"]) {
		WAHowItWorksViewController *terms = [[WAHowItWorksViewController alloc] init];
		terms.ios5Style = YES;
		page = terms;
	} else page = [[WAHelloViewController alloc] init];
	commandNav = [[UINavigationController alloc] initWithRootViewController:page];
	[page setValue:^{ [WADevCloser close]; } forKey:@"finished"];
	page.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
		target:[WADevCloser class] action:@selector(close)];
	UIViewController *top = mainWindow.rootViewController;
	while (top.presentedViewController) top = top.presentedViewController;
	[top presentViewController:commandNav animated:NO completion:nil];
}

// junk of growing size to /api/sendimage without a chat over the current server: the bridge reads it
// all, then says 400. nothing goes to whatsapp. results in the log ("dev: upload ...")
static void UploadTest(NSArray *sizes) {
	if (!sizes.count) return;
	NSUInteger size = [sizes[0] unsignedIntegerValue];
	NSMutableData *body = [NSMutableData dataWithLength:size];
	for (NSUInteger k = 0; k < size; k++) ((unsigned char *)body.mutableBytes)[k] = (unsigned char)(k * 31 + 7);
	NSDate *start = [NSDate date];
	[[WAClient shared] post:@"/api/sendimage" params:@{} data:body contentType:@"image/jpeg" completion:^(id json, NSError *error) {
		WALog(@"dev: upload %lu bytes -> %@ (%.1f s)", (unsigned long)size, error ? [NSString stringWithFormat:@"%ld %@", (long)error.code, error.localizedDescription] : @"ok",
			-[start timeIntervalSinceNow]);
		UploadTest([sizes subarrayWithRange:NSMakeRange(1, sizes.count - 1)]);
	}];
}

static void Command(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
	NSString *what = [(__bridge NSString *)name pathExtension];
	WALog(@"dev: command %@", what);
	if ([what hasPrefix:@"calls"]) CallsCommand(what);
	else if ([what hasPrefix:@"hello"]) HelloCommand(what);
	else if ([what isEqualToString:@"uploadtest"]) UploadTest(@[@20000, @300000, @1000000, @3000000]);
	else if ([what isEqualToString:@"statustab"]) SetStatusTab(!StatusTabOn());
	else if ([what isEqualToString:@"menu"]) Show(nil);
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
	for (NSString *what in @[@"menu", @"tests", @"stats", @"manual", @"log", @"close", @"message", @"clear", @"ring", @"hangup", @"banner",
		@"calls", @"callsall", @"callsmissed", @"callsnew", @"callsedit", @"statustab", @"hello", @"hellodiag", @"hellothanks", @"helloterms", @"helloconnect", @"helloqr", @"helloloading", @"uploadtest"]) {
		NSString *name = [@"com.aronsz26.wa4s.dev." stringByAppendingString:what];
		CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, Command, (__bridge CFStringRef)name, NULL,
			CFNotificationSuspensionBehaviorDeliverImmediately);
	}
}
