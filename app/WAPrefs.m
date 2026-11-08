#import <AudioToolbox/AudioToolbox.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <netinet/in.h>
#import "WAPrefs.h"

NSString *const WAPrefMessageAlerts = @"msgAlerts", *const WAPrefMessageSound = @"msgSound";
NSString *const WAPrefGroupAlerts = @"groupAlerts", *const WAPrefGroupSound = @"groupSound";
NSString *const WAPrefShowPreview = @"showPreview";
NSString *const WAPrefInAppSounds = @"inAppSounds", *const WAPrefInAppVibrate = @"inAppVibrate", *const WAPrefInAppPreview = @"inAppPreview";
NSString *const WAPrefMessageTimestamp = @"messageTimestamp", *const WAPrefSaveIncomingMedia = @"saveIncomingMedia";
NSString *const WAPrefAutoDownload = @"autoDownload";
NSString *const WAPrefWallpaper = @"wallpaper";
NSString *const WAPrefAutoPhotos = @"autoPhotos", *const WAPrefAutoAudio = @"autoAudio", *const WAPrefAutoVideos = @"autoVideos";
NSString *const WAPrefOptimizeVideo = @"optimizeVideo";
NSString *const WAPrefVideoCalls = @"videoCalls";
NSString *const WAPrefBubbleOut = @"bubbleOut", *const WAPrefBubbleIn = @"bubbleIn";
NSString *const WAPrefsChangedNotification = @"WAPrefsChangedNotification";

static void RegisterDefaults(void) {
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		// migrate old auto-download switch
		id old = [[NSUserDefaults standardUserDefaults] objectForKey:WAPrefAutoDownload];
		NSString *photos = old && ![old boolValue] ? @"never" : @"all";
		[[NSUserDefaults standardUserDefaults] registerDefaults:@{
			WAPrefAutoPhotos: photos, WAPrefAutoAudio: @"wifi", WAPrefAutoVideos: @"never", WAPrefOptimizeVideo: @"cellular",
			WAPrefBubbleOut: @"Green", WAPrefBubbleIn: @"White",
			WAPrefMessageAlerts: @YES, WAPrefMessageSound: @"Tri-tone", WAPrefGroupAlerts: @YES, WAPrefGroupSound: @"Tri-tone",
			WAPrefShowPreview: @YES, WAPrefInAppSounds: @YES, WAPrefInAppVibrate: @YES, WAPrefInAppPreview: @YES,
			WAPrefMessageTimestamp: @YES, WAPrefSaveIncomingMedia: @NO, WAPrefAutoDownload: @YES,
		}];
	});
}

BOOL WAPrefBool(NSString *key) {
	RegisterDefaults();
	return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

BOOL WAVideoCallsEnabled(void) {
#ifdef WA_DEV
	return WAPrefBool(WAPrefVideoCalls);
#else
	return NO; // the dev switch stays in the prefs after going back to the normal app
#endif
}

NSString *WAPrefString(NSString *key) {
	RegisterDefaults();
	return [[NSUserDefaults standardUserDefaults] stringForKey:key];
}

void WASetPref(NSString *key, id value) {
	RegisterDefaults();
	if (value) [[NSUserDefaults standardUserDefaults] setObject:value forKey:key];
	else [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
	[[NSUserDefaults standardUserDefaults] synchronize];
	[[NSNotificationCenter defaultCenter] postNotificationName:WAPrefsChangedNotification object:key];
}

NSArray *WASoundNames(void) {
	return @[@"None", @"Default", @"Tri-tone", @"Xylophone", @"Bell", @"Boing", @"Glass", @"Harp", @"Time Passing"];
}

NSString *WASoundFile(NSString *name) {
	if ([name isEqualToString:@"None"]) return nil;
	if ([name isEqualToString:@"Default"]) return UILocalNotificationDefaultSoundName;
	NSString *file = [[name stringByReplacingOccurrencesOfString:@" " withString:@""] stringByAppendingPathExtension:@"caf"];
	// empty placeholder until the bridge has the sounds, ios plays nothing at all for those
	NSString *path = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:file];
	if ([[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL].fileSize > 0) return file;
	return UILocalNotificationDefaultSoundName;
}

void WAPlaySound(NSString *name) {
	static NSMutableDictionary *ids;
	if (!ids) ids = [NSMutableDictionary dictionary];
	NSString *file = WASoundFile(name);
	if (!file) return;
	if ([file isEqualToString:UILocalNotificationDefaultSoundName]) {
		AudioServicesPlaySystemSound(1007); // default sms tone
		return;
	}
	NSNumber *sid = ids[file];
	if (!sid) {
		SystemSoundID s = 0;
		NSURL *url = [NSURL fileURLWithPath:[[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:file]];
		if (AudioServicesCreateSystemSoundID((__bridge CFURLRef)url, &s) != noErr) return;
		ids[file] = sid = @(s);
	}
	AudioServicesPlaySystemSound((SystemSoundID)[sid unsignedIntValue]);
}

BOOL WAOnWiFi(void) {
	struct sockaddr_in zero = {0};
	zero.sin_len = sizeof(zero);
	zero.sin_family = AF_INET;
	SCNetworkReachabilityRef r = SCNetworkReachabilityCreateWithAddress(NULL, (const struct sockaddr *)&zero);
	SCNetworkReachabilityFlags flags = 0;
	BOOL ok = r && SCNetworkReachabilityGetFlags(r, &flags);
	if (r) CFRelease(r);
	return ok && (flags & kSCNetworkReachabilityFlagsReachable) && !(flags & kSCNetworkReachabilityFlagsIsWWAN);
}

BOOL WAAutoDownload(NSString *key) {
	NSString *v = WAPrefString(key);
	if ([v isEqualToString:@"all"]) return YES;
	return [v isEqualToString:@"wifi"] && WAOnWiFi();
}

BOOL WAOptimizeVideoNow(void) {
	NSString *v = WAPrefString(WAPrefOptimizeVideo);
	if ([v isEqualToString:@"always"]) return YES;
	return [v isEqualToString:@"cellular"] && !WAOnWiFi();
}

NSString *WAChatBubble(NSString *jid, BOOL mine) {
	if (!jid) return nil;
	NSDictionary *all = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"chatBubbles"];
	return all[jid][mine ? @"out" : @"in"];
}

NSString *WABubbleColorName(NSString *jid, BOOL mine) {
	return WAChatBubble(jid, mine) ?: WAPrefString(mine ? WAPrefBubbleOut : WAPrefBubbleIn);
}

void WASetChatBubble(NSString *jid, BOOL mine, NSString *name) {
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	NSMutableDictionary *all = [[d dictionaryForKey:@"chatBubbles"] mutableCopy] ?: [NSMutableDictionary dictionary];
	NSMutableDictionary *chat = [all[jid] mutableCopy] ?: [NSMutableDictionary dictionary];
	if (name) chat[mine ? @"out" : @"in"] = name;
	else [chat removeObjectForKey:mine ? @"out" : @"in"];
	if (chat.count) all[jid] = chat; else [all removeObjectForKey:jid];
	WASetPref(@"chatBubbles", all);
}
