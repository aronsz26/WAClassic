#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import "WAChatListViewController.h"
#import "WAChatViewController.h"
#import "WASettingsViewController.h"
#import "WASettingsPages.h"
#import "WAContactsViewController.h"
#import "WAStatusViewController.h"
#import "WAPrefs.h"
#import "WAFavoritesViewController.h"
#import "WATooltip.h"
#import "WAClient.h"
#import "WAAssets.h"
#import "WABackground.h"
#import "WABanner.h"
#import "WAUtil.h"
#import "WACall.h"
#import "WACallViewController.h"
#import "WAVideoCallViewController.h"
#import "WASetupViewController.h"
#import "WABubbles.h"
#import "WAUpdate.h"
#import "WADiag.h"
#import "WAHello.h"
#import "WATLSFix.h"
#ifdef WA_DEV
#import "dev/WADev.h"
#endif

@interface WAAppDelegate : UIResponder <UIApplicationDelegate, UITabBarControllerDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) WATooltip *tooltip;
@property (nonatomic, strong) WAChatListViewController *chats;
@property (nonatomic, strong) UINavigationController *setup;
@property (nonatomic) BOOL bridgeVersionChecked; // once per start
@property (nonatomic) BOOL assetsArrived; // rebuild tabs when nothing is open
@end

@implementation WAAppDelegate

static UINavigationController *Nav(UIViewController *root) {
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
	nav.tabBarItem = root.tabBarItem;
	return nav;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	WALog(@"launch (state %d)", (int)application.applicationState);
	// no url cache, the sqlite lock got us killed (0xdead10cc)
	[NSURLCache setSharedURLCache:[[NSURLCache alloc] initWithMemoryCapacity:0 diskCapacity:0 diskPath:nil]];
	UITabBarController *tabs = [self makeTabs];
	tabs.selectedIndex = [WAClient shared].configured ? 3 : 4;
	if (![WAClient shared].configured) dispatch_async(dispatch_get_main_queue(), ^{ [self checkLinked]; });
	else [[WAClient shared] chooseServer:^(BOOL reachable) {
		if (!reachable) return;
		[self.chats reload];
		[self checkLinked];
		[self showSettingsTooltipSoon];
		[self syncAssets];
	}];
	self.window.rootViewController = tabs;
	[self.window makeKeyAndVisible];
#ifdef WA_DEV
	WADevStart(self.window);
#endif
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updatesArrived:)
		name:WAClientUpdatesNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(openChatRequested:)
		name:@"WAOpenChatNotification" object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(callChanged)
		name:WACallChangedNotification object:[WACall shared]];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(showSetup)
		name:WALinkNeededNotification object:nil];
	UILocalNotification *note = launchOptions[UIApplicationLaunchOptionsLocalNotificationKey];
	if ([note.userInfo[@"call"] length]) [self answerCall:note.userInfo[@"call"]];
	else if (note.userInfo[@"chat"]) [self openChat:note.userInfo[@"chat"]];
	// voip relaunch after reboot
	if (application.applicationState == UIApplicationStateBackground) [[WABackground shared] start];
	return YES;
}

// the 5 tabs of 2.10
- (UITabBarController *)makeTabs {
	self.chats = [[WAChatListViewController alloc] initWithStyle:UITableViewStylePlain];
	UITabBarController *tabs = [[UITabBarController alloc] init];
	tabs.viewControllers = @[
		Nav([[WAFavoritesViewController alloc] init]),
#ifdef WA_DEV
		Nav(WADevSecondTab()),
#else
		Nav([[WAStatusViewController alloc] init]),
#endif
		Nav([[WAContactsViewController alloc] init]),
		Nav(self.chats),
		Nav([[WASettingsRootViewController alloc] init]),
	];
	tabs.delegate = self;
	return tabs;
}

// fetch assets, foreground only
- (void)syncAssets {
	if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) return;
	WAAssetsSync(^{
		WABubblesReset();
		self.assetsArrived = YES;
		[self applyAssetsIfIdle];
	});
}

// rebuild tabs for new graphics, but not while something is open
- (void)applyAssetsIfIdle {
	UITabBarController *tabs = (UITabBarController *)self.window.rootViewController;
	if (!self.assetsArrived || self.setup || self.tooltip || tabs.presentedViewController) return;
	for (UINavigationController *nav in tabs.viewControllers) {
		if (nav.viewControllers.count > 1) return;
	}
	WALog(@"assets: new graphics, building the tabs again");
	self.assetsArrived = NO;
	NSUInteger selected = tabs.selectedIndex;
	UITabBarController *fresh = [self makeTabs];
	fresh.selectedIndex = selected;
	self.window.rootViewController = fresh;
	if ([WAClient shared].configured) [self.chats reload];
}

- (void)application:(UIApplication *)application didReceiveLocalNotification:(UILocalNotification *)notification {
	// tapped a notification
	if (application.applicationState == UIApplicationStateActive) return;
	if ([notification.userInfo[@"call"] length]) [self answerCall:notification.userInfo[@"call"]];
	else if (notification.userInfo[@"chat"]) [self openChat:notification.userInfo[@"chat"]];
}

// answer action from the notification
- (void)answerCall:(NSString *)callID {
	[[WAClient shared] get:@"/api/call/state" params:nil completion:^(id json, NSError *error) {
		if (error) return;
		[[WACall shared] updateWithInfo:json];
		if ([json[@"id"] isEqualToString:callID] && [json[@"state"] isEqualToString:@"ringing"]) [[WACall shared] answer];
	}];
}

// not linked yet -> setup
- (void)checkLinked {
	if (self.setup) return;
	if (![WAClient shared].configured) {
		[self showSetup];
		return;
	}
	[[WAClient shared] get:@"/api/status" params:nil completion:^(id json, NSError *error) {
		if (![json isKindOfClass:[NSDictionary class]]) return;
		if (json[@"paired"] && ![json[@"paired"] boolValue]) [self showSetup];
		else {
			[[WADiag shared] noteBridge:json];
			[self checkBridgeVersion:json[@"version"]];
		}
	}];
}

// app newer than the bridge -> say so, again on the next start
- (void)checkBridgeVersion:(NSString *)bridge {
	if (self.bridgeVersionChecked || [UIApplication sharedApplication].applicationState == UIApplicationStateBackground) return;
	self.bridgeVersionChecked = YES;
	NSString *app = [NSBundle mainBundle].infoDictionary[@"CFBundleVersion"];
	WALog(@"bridge version %@, app %@", bridge ?: @"none", app);
	// old bridges don't send one, own builds say dev
	if ([bridge isEqualToString:@"dev"]) return;
	if (bridge.length && [bridge compare:app options:NSNumericSearch] != NSOrderedAscending) return;
	[[[UIAlertView alloc] initWithTitle:@"Update Your Bridge"
		message:@"WA Classic was updated, but your bridge is still on an older version. Some things may not work. To update it, see guide.waclassic.com/updating on your computer."
		delegate:nil cancelButtonTitle:@"Dismiss" otherButtonTitles:nil] show];
}

// settings tooltip, once
- (void)showSettingsTooltipSoon {
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		[self applyAssetsIfIdle];
		NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
		if (self.tooltip || self.setup || [d boolForKey:@"settingsTooltipShown"] || ![WAClient shared].configured) return;
		UITabBarController *tabs = (UITabBarController *)self.window.rootViewController;
		UITabBar *bar = tabs.tabBar;
		CGFloat itemW = bar.bounds.size.width / tabs.viewControllers.count;
		CGPoint tip = [tabs.view convertPoint:CGPointMake(itemW * 4.5, 4) fromView:bar];
		self.tooltip = [WATooltip showText:@"Edit your message notifications, set profile photo and many other things"
			pointingAt:tip inView:tabs.view];
		__weak WAAppDelegate *weak = self;
		self.tooltip.onClose = ^{ [weak settingsTooltipDone]; };
	});
}

- (void)settingsTooltipDone {
	[self.tooltip dismiss];
	self.tooltip = nil;
	[[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"settingsTooltipShown"];
	[[NSUserDefaults standardUserDefaults] synchronize];
	[self applyAssetsIfIdle];
}

// opened settings, hide tooltip
- (void)tabBarController:(UITabBarController *)tabs didSelectViewController:(UIViewController *)vc {
	if (self.tooltip && tabs.selectedIndex == 4) [self settingsTooltipDone];
}

- (void)showSetup {
	if (self.setup) return;
	WALog(@"setup: bridge not linked");
	__weak WAAppDelegate *weak = self;
	void (^done)(void) = ^{
		WAAppDelegate *me = weak;
		[me.setup dismissViewControllerAnimated:YES completion:nil];
		me.setup = nil;
		UITabBarController *tabs = (UITabBarController *)me.window.rootViewController;
		tabs.selectedIndex = 3;
		[me.chats reload];
		[me syncAssets];
		[me showSettingsTooltipSoon];
	};
	UIViewController *first;
	if (![WAClient shared].configured) {
		// new install: ios 5 setup look, thank you page after the chats
		WAHelloViewController *hello = [[WAHelloViewController alloc] init];
		hello.finished = ^{
			WAThankYouViewController *thanks = [[WAThankYouViewController alloc] init];
			thanks.finished = done;
			[weak.setup pushViewController:thanks animated:YES];
		};
		first = hello;
	} else {
		// bridge unlinked later: the short 2.10 way
		WAWelcomeViewController *welcome = [[WAWelcomeViewController alloc] init];
		welcome.finished = done;
		first = welcome;
	}
	self.setup = [[UINavigationController alloc] initWithRootViewController:first];
	UIViewController *top = self.window.rootViewController;
	while (top.presentedViewController) top = top.presentedViewController;
	[top presentViewController:self.setup animated:YES completion:nil];
}

- (void)callChanged {
	[WACallViewController showIfNeededInWindow:self.window];
	[WAVideoCallViewController showIfNeededInWindow:self.window];
}

- (UINavigationController *)chatsNav {
	UITabBarController *tabs = (UITabBarController *)self.window.rootViewController;
	return tabs.viewControllers[3];
}

// open chat from contact info
- (void)openChatRequested:(NSNotification *)note {
	[self openChat:note.userInfo[@"jid"] name:note.userInfo[@"name"] group:[note.userInfo[@"group"] boolValue]];
}

- (void)openChat:(NSString *)jid {
	[self openChat:jid name:nil group:NO];
}

- (void)openChat:(NSString *)jid name:(NSString *)name group:(BOOL)group {
	[[WAClient shared] get:@"/api/chats" params:nil completion:^(id json, NSError *error) {
		NSMutableArray *chats = [NSMutableArray arrayWithArray:[json[@"chats"] isKindOfClass:[NSArray class]] ? json[@"chats"] : @[]];
		if (name) [chats addObject:@{@"jid": jid, @"name": name, @"group": @(group)}];
		for (NSDictionary *chat in chats) {
			if (![chat[@"jid"] isEqualToString:jid]) continue;
			UITabBarController *tabs = (UITabBarController *)self.window.rootViewController;
			tabs.selectedIndex = 3;
			UINavigationController *nav = [self chatsNav];
			WAChatViewController *top = (WAChatViewController *)nav.topViewController;
			if ([top isKindOfClass:[WAChatViewController class]] && [top.jid isEqualToString:jid]) return;
			[nav popToRootViewControllerAnimated:NO];
			[nav pushViewController:[[WAChatViewController alloc] initWithChat:chat] animated:NO];
			return;
		}
	}];
}

// in-app banner for other chats
- (void)updatesArrived:(NSNotification *)note {
	if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
	UITabBarController *tabs = (UITabBarController *)self.window.rootViewController;
	WAChatViewController *open = (WAChatViewController *)[self chatsNav].topViewController;
	NSString *openJID = tabs.selectedIndex == 3 && [open isKindOfClass:[WAChatViewController class]] ? open.jid : nil;
	long long now = (long long)[[NSDate date] timeIntervalSince1970];
	for (NSDictionary *m in note.userInfo[@"messages"]) {
		if ([m[@"fromMe"] boolValue] || [m[@"chat"] isEqualToString:openJID]) continue;
		if ([m[@"kind"] isEqualToString:@"call"]) continue;
		if ([m[@"status"] intValue] >= 3 || [m[@"ts"] longLongValue] < now - 120) continue;
		if ([self.shownBanners containsObject:m[@"seq"]]) continue;
		[self.shownBanners addObject:m[@"seq"]];
		NSString *jid = m[@"chat"];
		// in-app sounds/vibrate/preview
		BOOL group = [jid hasSuffix:@"@g.us"];
		if (WAPrefBool(WAPrefInAppSounds)) WAPlaySound(WAPrefString(group ? WAPrefGroupSound : WAPrefMessageSound));
		if (WAPrefBool(WAPrefInAppVibrate)) AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
		if (WAPrefBool(WAPrefInAppPreview)) {
			[WABanner showText:WANotificationText(m) inWindow:self.window onTap:^{ [self openChat:jid]; }];
		}
	}
}

- (NSMutableSet *)shownBanners {
	static NSMutableSet *set;
	if (!set) set = [NSMutableSet set];
	return set;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
	[[WABackground shared] stop];
	[[WAClient shared] setOnline:YES];
	[[WACall shared] refresh];
	[[WACall shared] tellCallScreen];
	[self callChanged];
	[self openRequestedChat];
	[self applyAssetsIfIdle];
	[[WADiag shared] noteLaunched];
	[[WADiag shared] askIfNeeded];
	[[WADiag shared] sendIfDue];
	[[WAUpdate shared] checkActive:YES];
}

// debug: jid in open-chat file opens that chat
- (void)openRequestedChat {
	NSString *path = @"/var/mobile/Library/WA4S/open-chat";
	NSString *jid = [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL]
		stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (!jid.length) return;
	[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
	[[WAClient shared] get:@"/api/chats" params:nil completion:^(id json, NSError *error) {
		for (NSDictionary *chat in json[@"chats"]) {
			if (![chat[@"jid"] isEqualToString:jid]) continue;
			UITabBarController *tabs = (UITabBarController *)self.window.rootViewController;
			tabs.selectedIndex = 3;
			UINavigationController *nav = (UINavigationController *)tabs.selectedViewController;
			[nav popToRootViewControllerAnimated:NO];
			[nav pushViewController:[[WAChatViewController alloc] initWithChat:chat] animated:NO];
		}
	}];
}

- (void)applicationWillResignActive:(UIApplication *)application {
	[[WAClient shared] setOnline:NO];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
	[[WAClient shared] stopUpdates];
	[[WABackground shared] start];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
	[[WAClient shared] chooseServer:^(BOOL reachable) {
		[self.chats reload];
		if (reachable) [self checkLinked];
		if (reachable) [self syncAssets];
	}];
}

@end

#ifdef WA_IOS4
void WAIOS4RuntimeInstall(void);
void WACompat4Install(void);
#endif

int main(int argc, char *argv[]) {
#ifdef WA_IOS4
	WAIOS4RuntimeInstall(); // 3gs build, must run before any weak ref
	WACompat4Install();
#endif
	@autoreleasepool {
		WATLSFixStart(); // before any tls
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([WAAppDelegate class]));
	}
}
