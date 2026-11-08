#import "WADiag.h"
#import "WAClient.h"
#import "WACall.h"
#import "WAAssets.h"
#import "WAUtil.h"
#include <sys/sysctl.h>

NSString *const WAPrefDiagnostics = @"diagOn";
static NSString *const kSend = @"http://update.waclassic.com/t";
static NSString *const kForget = @"http://update.waclassic.com/t/delete";
static NSString *const kCrashDir = @"/var/mobile/Library/Logs/CrashReporter";
static const NSTimeInterval kEvery = 24 * 3600;

@interface WADiag () <UIAlertViewDelegate>
@end

@implementation WADiag {
	BOOL _sending;
}

+ (instancetype)shared {
	static WADiag *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [[WADiag alloc] init]; });
	return shared;
}

- (NSUserDefaults *)d { return [NSUserDefaults standardUserDefaults]; }
- (BOOL)on { return [self.d boolForKey:WAPrefDiagnostics]; }

#pragma mark - Asking

- (void)askIfNeeded {
	if (_asking || [self.d boolForKey:@"diagAsked"] || ![WAClient shared].configured || [WACall shared].live) return;
	_asking = YES;
	UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Help Improve WA Classic?"
		message:@"Send anonymous diagnostics once a day: your iPhone model, iOS and app version, bridge version and system, language, crash reports and error codes.\n\nNever messages, contacts, numbers or names. You can change this in Settings › Chat Settings › Advanced."
		delegate:self cancelButtonTitle:@"Don't Send" otherButtonTitles:@"Send", nil];
	[alert show];
}

- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index {
	_asking = NO;
	[self.d setBool:YES forKey:@"diagAsked"];
	BOOL yes = index != alert.cancelButtonIndex;
	[self.d setBool:yes forKey:WAPrefDiagnostics];
	WALog(@"diagnostics: %@", yes ? @"yes" : @"no");
	if (yes) {
		// crashes from before the yes stay on the phone
		[self.d setDouble:[[NSDate date] timeIntervalSince1970] forKey:@"diagCrashSeen"];
		[self sendIfDue];
	}
}

#pragma mark - Collecting

- (NSString *)installID {
	NSString *uuid = [self.d stringForKey:@"diagID"];
	if (!uuid) {
		CFUUIDRef ref = CFUUIDCreate(NULL);
		uuid = (__bridge_transfer NSString *)CFUUIDCreateString(NULL, ref);
		CFRelease(ref);
		[self.d setObject:uuid forKey:@"diagID"];
	}
	return uuid;
}

static NSString *Machine(void) {
	size_t size = 0;
	sysctlbyname("hw.machine", NULL, &size, NULL, 0);
	char *buf = malloc(size + 1);
	if (!buf) return @"";
	sysctlbyname("hw.machine", buf, &size, NULL, 0);
	buf[size] = 0;
	NSString *out = [NSString stringWithUTF8String:buf] ?: @"";
	free(buf);
	return out;
}

static NSString *Today(void) {
	static NSDateFormatter *f;
	if (!f) {
		f = [[NSDateFormatter alloc] init];
		f.dateFormat = @"yyyy-MM-dd";
		f.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
	}
	return [f stringFromDate:[NSDate date]];
}

- (void)noteBridge:(NSDictionary *)status {
	if (![status isKindOfClass:[NSDictionary class]]) return;
	NSMutableDictionary *bridge = [NSMutableDictionary dictionary];
	for (NSString *key in @[@"version", @"platform", @"arch", @"kernel", @"docker"]) {
		if (status[key]) bridge[key] = status[key];
	}
	if (bridge.count) [self.d setObject:bridge forKey:@"diagBridge"];
}

- (void)record:(NSString *)code {
	if (!self.on || !code.length) return;
	if (code.length > 80) code = [code substringToIndex:80];
	NSMutableDictionary *days = [[self.d dictionaryForKey:@"diagErrors"] mutableCopy] ?: [NSMutableDictionary dictionary];
	NSString *today = Today();
	NSMutableDictionary *counts = [days[today] mutableCopy] ?: [NSMutableDictionary dictionary];
	if (counts.count >= 50 && !counts[code]) return;
	counts[code] = @([counts[code] integerValue] + 1);
	days[today] = counts;
	// two weeks at most if sending keeps failing
	for (NSString *day in [days.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
		if (days.count <= 14) break;
		[days removeObjectForKey:day];
	}
	[self.d setObject:days forKey:@"diagErrors"];
}

// the useful parts of a crash log only: exception, crashed thread, last exception backtrace, our binary images.
// no incident id or crashreporter key, those identify the phone
static NSString *ShortCrash(NSString *text) {
	NSMutableArray *out = [NSMutableArray array];
	NSArray *lines = [text componentsSeparatedByString:@"\n"];
	BOOL inBlock = NO, inImages = NO;
	NSUInteger blockLines = 0;
	for (NSString *line in lines) {
		if ([line hasPrefix:@"Exception Type"] || [line hasPrefix:@"Exception Codes"] || [line hasPrefix:@"Crashed Thread"] ||
			[line hasPrefix:@"OS Version"] || [line hasPrefix:@"Version:"]) {
			[out addObject:line];
			continue;
		}
		if (([line hasPrefix:@"Thread "] && [line hasSuffix:@"Crashed:"]) || [line hasPrefix:@"Last Exception Backtrace"]) {
			inBlock = YES;
			blockLines = 0;
			[out addObject:line];
			continue;
		}
		if ([line hasPrefix:@"Binary Images"]) {
			inImages = YES;
			[out addObject:line];
			continue;
		}
		if (inBlock) {
			if (!line.length || blockLines++ > 30) { inBlock = NO; continue; }
			[out addObject:line];
		} else if (inImages && ([line rangeOfString:@"WA4S"].location != NSNotFound || [line rangeOfString:@"WACallScreen"].location != NSNotFound)) {
			[out addObject:line];
		}
	}
	NSString *joined = [out componentsJoinedByString:@"\n"];
	return joined.length > 7500 ? [joined substringToIndex:7500] : joined;
}

- (NSArray *)newCrashes:(NSTimeInterval *)newest {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSTimeInterval seen = [self.d doubleForKey:@"diagCrashSeen"];
	*newest = seen;
	NSMutableArray *out = [NSMutableArray array];
	for (NSString *name in [fm contentsOfDirectoryAtPath:kCrashDir error:NULL]) {
		BOOL app = [name hasPrefix:@"WA4S_"], sb = [name hasPrefix:@"SpringBoard_"];
		if ((!app && !sb) || ![name hasSuffix:@".plist"] || out.count >= 5) continue;
		NSString *path = [kCrashDir stringByAppendingPathComponent:name];
		NSTimeInterval ts = [[fm attributesOfItemAtPath:path error:NULL].fileModificationDate timeIntervalSince1970];
		if (ts <= seen) continue;
		NSString *text = [NSDictionary dictionaryWithContentsOfFile:path][@"description"];
		if (![text isKindOfClass:[NSString class]]) continue;
		if (sb && [text rangeOfString:@"WACallScreen"].location == NSNotFound) continue; // springboard crashes that aren't ours
		[out addObject:@{@"ts": @((long long)ts), @"kind": sb ? @"springboard" : @"app", @"text": ShortCrash(text)}];
		*newest = MAX(*newest, ts);
	}
	return out;
}

#pragma mark - Sending

- (void)sendIfDue {
	if (!self.on || _sending) return;
	NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
	if (now - [self.d doubleForKey:@"diagSent"] < kEvery) return;
	NSTimeInterval newest = 0;
	NSArray *crashes = [self newCrashes:&newest];
	NSDictionary *days = [self.d dictionaryForKey:@"diagErrors"];
	NSMutableArray *errors = [NSMutableArray array];
	for (NSString *day in days) {
		for (NSString *code in days[day]) [errors addObject:@{@"day": day, @"code": code, @"n": days[day][code]}];
	}
	NSDictionary *bridge = [self.d dictionaryForKey:@"diagBridge"];
	WAClient *c = [WAClient shared];
#ifdef WA_IOS4
	NSString *pkg = @"ios4";
#else
	NSString *pkg = @"ios6";
#endif
	NSDictionary *report = @{
		@"id": [self installID], @"device": Machine(), @"ios": [UIDevice currentDevice].systemVersion ?: @"",
		@"app": [NSBundle mainBundle].infoDictionary[@"CFBundleVersion"] ?: @"", @"pkg": pkg,
		@"bridge": bridge[@"version"] ?: @"", @"platform": bridge[@"platform"] ?: @"", @"arch": bridge[@"arch"] ?: @"",
		@"kernel": bridge[@"kernel"] ?: @"", @"docker": @([bridge[@"docker"] boolValue]),
		@"away": @(c.awayURL.length > 0), @"look": @([[NSFileManager defaultManager] fileExistsAtPath:WAAssetPath(@"Tri-tone.caf")]),
		@"lang": [NSLocale preferredLanguages].firstObject ?: @"", @"crashes": crashes, @"errors": errors,
	};
	NSData *body = [NSJSONSerialization dataWithJSONObject:report options:0 error:NULL];
	if (!body) return;
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kSend]
		cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
	req.HTTPMethod = @"POST";
	[req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
	req.HTTPBody = body;
	_sending = YES;
	[c load:req completion:^(NSData *data, NSInteger status, NSError *error) {
		self->_sending = NO;
		if (error || status != 200) {
			WALog(@"diagnostics: send failed %ld %@", (long)status, error.localizedDescription);
			return;
		}
		[self.d setDouble:now forKey:@"diagSent"];
		[self.d removeObjectForKey:@"diagErrors"];
		if (newest > [self.d doubleForKey:@"diagCrashSeen"]) [self.d setDouble:newest forKey:@"diagCrashSeen"];
		WALog(@"diagnostics: sent (%lu crashes, %lu error codes)", (unsigned long)crashes.count, (unsigned long)errors.count);
	}];
}

- (void)turnedOff {
	NSString *uuid = [self.d stringForKey:@"diagID"];
	[self.d removeObjectForKey:@"diagErrors"];
	[self.d removeObjectForKey:@"diagSent"];
	if (!uuid) return;
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kForget]
		cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
	req.HTTPMethod = @"POST";
	[req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
	req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"id": uuid} options:0 error:NULL];
	[[WAClient shared] load:req completion:^(NSData *data, NSInteger status, NSError *error) {
		WALog(@"diagnostics: delete %ld", (long)status);
		// new id next time, so old and new can't be linked
		if (!error && status == 200) [self.d removeObjectForKey:@"diagID"];
	}];
}

@end
