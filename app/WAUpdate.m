#import "WAUpdate.h"
#import "WAClient.h"
#import "WACall.h"
#import "WAUtil.h"
#import "WADiag.h"

// plain http, ios 4-6 can't do cloudflare's tls. the button is ours, the server only sends version and text
static NSString *const kURL = @"http://update.waclassic.com/latest.json";
static const NSTimeInterval kEvery = 6 * 3600;

@interface WAUpdate () <UIAlertViewDelegate>
@end

@implementation WAUpdate {
	BOOL _loading, _showing;
	NSString *_offered;
}

+ (instancetype)shared {
	static WAUpdate *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [[WAUpdate alloc] init]; });
	return shared;
}

- (NSString *)package {
#ifdef WA_IOS4
	return @"com.aronsz26.wa4s-ios4";
#else
	return @"com.aronsz26.wa4s";
#endif
}

- (void)checkActive:(BOOL)active {
	if (![WAClient shared].configured) return; // still setting up
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
	if (now - [d doubleForKey:@"updChecked"] < kEvery || _loading) {
		[self offer:[d dictionaryForKey:@"updLatest"] active:active];
		return;
	}
	_loading = YES;
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kURL]
		cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
	[[WAClient shared] load:req completion:^(NSData *data, NSInteger status, NSError *error) {
		self->_loading = NO;
		NSDictionary *latest = [self parse:data];
		if (error || status != 200 || !latest) {
			WALog(@"update check: %ld %@", (long)status, error.localizedDescription);
			return;
		}
		[d setDouble:now forKey:@"updChecked"];
		[d setObject:latest forKey:@"updLatest"];
		// background: the app might not be active anymore by now
		[self offer:latest active:active && [UIApplication sharedApplication].applicationState == UIApplicationStateActive];
	}];
}

// only what we need, nothing that could be a link
- (NSDictionary *)parse:(NSData *)data {
	id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
	if (![json isKindOfClass:[NSDictionary class]]) return nil;
	NSString *version = json[@"version"];
	if (![version isKindOfClass:[NSString class]] || !version.length || version.length > 12 ||
		[version rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789."] invertedSet]].location != NSNotFound)
		return nil;
	NSString *notes = [json[@"notes"] isKindOfClass:[NSString class]] ? json[@"notes"] : @"";
	if (notes.length > 300) notes = [notes substringToIndex:300];
	return @{@"version": version, @"notes": notes, @"important": @([json[@"important"] boolValue])};
}

- (void)offer:(NSDictionary *)latest active:(BOOL)active {
	NSString *version = latest[@"version"];
	NSString *mine = [NSBundle mainBundle].infoDictionary[@"CFBundleVersion"];
	if (!version || [version compare:mine options:NSNumericSearch] != NSOrderedDescending) return;
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	if (!active) {
		if ([[d stringForKey:@"updNotified"] isEqualToString:version]) return;
		[d setObject:version forKey:@"updNotified"];
		UILocalNotification *n = [[UILocalNotification alloc] init];
		n.alertBody = [NSString stringWithFormat:@"WA Classic %@ is available. Tap to update.", version];
		n.alertAction = @"Update";
		n.userInfo = @{@"update": version};
		[[UIApplication sharedApplication] presentLocalNotificationNow:n];
		WALog(@"update: %@ notification shown", version);
		return;
	}
	if (_showing || [WACall shared].live || [WADiag shared].asking) return;
	if ([[d stringForKey:@"updLater"] isEqualToString:version] && ![latest[@"important"] boolValue]) return;
	_showing = YES;
	_offered = version;
	NSString *notes = [latest[@"notes"] length] ? latest[@"notes"] : @"Update it in Cydia.";
	[[[UIAlertView alloc] initWithTitle:[NSString stringWithFormat:@"WA Classic %@ is available", version] message:notes
		delegate:self cancelButtonTitle:@"Later" otherButtonTitles:@"Open Cydia", nil] show];
	WALog(@"update: %@ offered", version);
}

- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index {
	_showing = NO;
	if (!_offered) return;
	if (index == alert.cancelButtonIndex) {
		[[NSUserDefaults standardUserDefaults] setObject:_offered forKey:@"updLater"];
		return;
	}
	NSURL *cydia = [NSURL URLWithString:[@"cydia://package/" stringByAppendingString:[self package]]];
	if (![[UIApplication sharedApplication] openURL:cydia]) {
		[[[UIAlertView alloc] initWithTitle:@"Open Cydia" message:@"Open Cydia, go to Changes and update WA Classic there."
			delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
	}
}

@end
