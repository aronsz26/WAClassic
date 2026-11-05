#import <CommonCrypto/CommonDigest.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import "WAClient.h"
#import "WAUtil.h"

NSString *const WAClientUpdatesNotification = @"WAClientUpdatesNotification";
NSString *const WAClientServerChangedNotification = @"WAClientServerChangedNotification";
NSString *const WAClientNetworkChangedNotification = @"WAClientNetworkChangedNotification";

BOOL WAPinMatches(SecTrustRef trust, NSString *pin) {
	if (!trust || SecTrustGetCertificateCount(trust) < 1 || pin.length != 64) return NO;
	SecCertificateRef cert = SecTrustGetCertificateAtIndex(trust, 0);
	NSData *der = CFBridgingRelease(SecCertificateCopyData(cert));
	unsigned char sum[CC_SHA256_DIGEST_LENGTH];
	CC_SHA256(der.bytes, (CC_LONG)der.length, sum);
	NSMutableString *hex = [NSMutableString string];
	for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", sum[i]];
	return [hex isEqualToString:pin.lowercaseString];
}

// delegate request so we can accept the pinned self-signed cert
@interface WAConnection : NSObject <NSURLConnectionDataDelegate>
@property (nonatomic, copy) NSString *pin;
@property (nonatomic, copy) void (^completion)(NSData *data, NSInteger status, NSError *error);
@property (nonatomic, strong) NSMutableData *data;
@property (nonatomic) NSInteger status;
@end

@implementation WAConnection

static NSMutableSet *running;

+ (void)load:(NSURLRequest *)request pin:(NSString *)pin completion:(void (^)(NSData *, NSInteger, NSError *))completion {
	if (!running) running = [NSMutableSet set];
	WAConnection *c = [[WAConnection alloc] init];
	c.pin = pin;
	c.completion = completion;
	c.data = [NSMutableData data];
	[running addObject:c];
	[NSURLConnection connectionWithRequest:request delegate:c];
}

- (void)connection:(NSURLConnection *)connection willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
	NSURLProtectionSpace *space = challenge.protectionSpace;
	if ([space.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
		if (WAPinMatches(space.serverTrust, self.pin)) {
			[challenge.sender useCredential:[NSURLCredential credentialForTrust:space.serverTrust] forAuthenticationChallenge:challenge];
		} else {
			WALog(@"certificate does not match the pin");
			[challenge.sender cancelAuthenticationChallenge:challenge];
		}
		return;
	}
	[challenge.sender performDefaultHandlingForAuthenticationChallenge:challenge];
}

// ios 4 uses these instead
- (BOOL)connection:(NSURLConnection *)connection canAuthenticateAgainstProtectionSpace:(NSURLProtectionSpace *)space {
	return [space.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust];
}

- (void)connection:(NSURLConnection *)connection didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
	[self connection:connection willSendRequestForAuthenticationChallenge:challenge];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
	self.status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
	self.data.length = 0;
}

- (NSCachedURLResponse *)connection:(NSURLConnection *)connection willCacheResponse:(NSCachedURLResponse *)cachedResponse {
	return nil;
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
	[self.data appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
	self.completion(self.data, self.status, nil);
	[running removeObject:self];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
	self.completion(nil, 0, error);
	[running removeObject:self];
}

@end

static NSString *const kDomain = @"com.aronsz26.wa4s";

NSString *WAEscape(NSString *s) {
	CFStringRef out = CFURLCreateStringByAddingPercentEscapes(NULL, (__bridge CFStringRef)(s ?: @""), NULL,
		CFSTR("!*'();:@&=+$,/?%#[] "), kCFStringEncodingUTF8);
	return CFBridgingRelease(out);
}

@implementation WAClient {
	BOOL _polling;
	NSUInteger _pollGeneration;
	long long _upd;
	NSString *_serverURL;
	BOOL _away;
	NSUInteger _pollErrors;
	NSCache *_avatars;
	NSMutableDictionary *_avatarWaiters;
	NSMutableSet *_noAvatar;
}

+ (WAClient *)shared {
	static WAClient *client;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ client = [[WAClient alloc] init]; });
	return client;
}

- (instancetype)init {
	if ((self = [super init])) {
		_avatars = [[NSCache alloc] init];
		_avatarWaiters = [NSMutableDictionary dictionary];
		_noAvatar = [NSMutableSet set];
		NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
		_homeURL = [([d stringForKey:@"homeURL"] ?: [d stringForKey:@"serverURL"]) copy]; // old single address
		_awayURL = [[d stringForKey:@"awayURL"] copy];
		_pin = [[d stringForKey:@"pin"] copy];
		_token = [[d stringForKey:@"token"] copy];
		_upd = [[d objectForKey:@"upd"] longLongValue];
		// last used address, faster bg relaunch away from home
		_away = [d boolForKey:@"lastAway"] && _awayURL.length;
		_serverURL = [(_away || !_homeURL.length ? _awayURL : _homeURL) copy];
		[self watchNetwork];
	}
	return self;
}

// network changed, recheck
static void NetworkChanged(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info) {
	WALog(@"network changed (flags %x)", flags);
	[[WAClient shared] chooseServer:nil];
	[[NSNotificationCenter defaultCenter] postNotificationName:WAClientNetworkChangedNotification object:nil];
}

- (void)watchNetwork {
	// any host works here
	NSString *host = [NSURL URLWithString:self.awayURL ?: @""].host ?: @"apple.com";
	SCNetworkReachabilityRef r = SCNetworkReachabilityCreateWithName(NULL, host.UTF8String);
	if (!r) return;
	SCNetworkReachabilitySetCallback(r, NetworkChanged, NULL);
	SCNetworkReachabilityScheduleWithRunLoop(r, CFRunLoopGetMain(), kCFRunLoopCommonModes);
}

- (BOOL)configured {
	return (self.homeURL.length > 0 || self.awayURL.length > 0) && self.token.length > 0;
}

- (NSString *)serverURL {
	return _serverURL;
}

- (BOOL)away {
	return _away;
}

- (void)saveSettings {
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	[d setObject:self.homeURL ?: @"" forKey:@"homeURL"];
	[d setObject:self.awayURL ?: @"" forKey:@"awayURL"];
	[d setObject:self.pin ?: @"" forKey:@"pin"];
	[d setObject:self.token ?: @"" forKey:@"token"];
	[d removeObjectForKey:@"serverURL"];
	[d synchronize];
	if (![_serverURL isEqualToString:self.homeURL] && ![_serverURL isEqualToString:self.awayURL]) {
		_serverURL = [(self.homeURL.length ? self.homeURL : self.awayURL) copy];
	}
}

- (void)setupWithAddress:(NSString *)address code:(NSString *)code completion:(void (^)(NSError *))completion {
	NSString *base = [address stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
	while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
	if (![base hasPrefix:@"http://"] && ![base hasPrefix:@"https://"]) base = [@"http://" stringByAppendingString:base];
	NSURL *url = [NSURL URLWithString:base];
	if (!url.host.length) {
		completion([NSError errorWithDomain:@"WA4S" code:0 userInfo:@{NSLocalizedDescriptionKey: @"Please enter the address of your bridge."}]);
		return;
	}
	if (!url.port) base = [base stringByAppendingString:@":8097"];
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/api/setup"]]
		cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
	req.HTTPMethod = @"POST";
	[req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
	req.HTTPBody = [[@"code=" stringByAppendingString:WAEscape(code)] dataUsingEncoding:NSUTF8StringEncoding];
	[WAConnection load:req pin:nil completion:^(NSData *data, NSInteger status, NSError *error) {
		id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
		if (error || status != 200 || ![json isKindOfClass:[NSDictionary class]] || ![json[@"token"] length]) {
			NSString *msg = error ? @"The bridge could not be reached. Check the address and that this iPhone is on the same Wi-Fi."
				: status == 403 ? @"Wrong or expired setup code. Restart the bridge for a new one."
				: [NSString stringWithFormat:@"This is not a WA Classic bridge (error %ld).", (long)status];
			WALog(@"setup code: status %ld %@", (long)status, error.localizedDescription ?: @"");
			completion([NSError errorWithDomain:@"WA4S" code:status userInfo:@{NSLocalizedDescriptionKey: msg}]);
			return;
		}
		self.homeURL = base;
		self.awayURL = json[@"awayURL"] ?: @"";
		self.pin = json[@"pin"] ?: @"";
		self.token = json[@"token"];
		[self saveSettings];
		[self useServer:base away:NO];
		completion(nil);
	}];
}

- (void)load:(NSURLRequest *)request completion:(void (^)(NSData *, NSInteger, NSError *))completion {
	[WAConnection load:request pin:self.pin completion:completion];
}

- (void)probe:(NSString *)base completion:(void (^)(BOOL ok))completion {
	if (!base.length) {
		completion(NO);
		return;
	}
	NSString *url = [[base stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]]
		stringByAppendingString:@"/api/status"];
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
		cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:4];
	[req setValue:self.token forHTTPHeaderField:@"X-WA4S-Token"];
	[self load:req completion:^(NSData *data, NSInteger status, NSError *error) {
		id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
		BOOL ok = status == 200 && [json isKindOfClass:[NSDictionary class]] && json[@"paired"] != nil;
		// bridge tells us away address + pin
		if (ok && [base isEqualToString:self.homeURL] && [json[@"awayURL"] length] && [json[@"pin"] length] &&
			(![json[@"awayURL"] isEqualToString:self.awayURL ?: @""] || ![json[@"pin"] isEqualToString:self.pin ?: @""])) {
			WALog(@"away address updated from the bridge");
			self.awayURL = json[@"awayURL"];
			self.pin = json[@"pin"];
			[self saveSettings];
		}
		completion(ok);
	}];
}

// try both, home wins. use away right away if that was last (no 4s wait)
- (void)chooseServer:(void (^)(BOOL reachable))done {
	__block BOOL homeDone = NO, awayDone = NO, awayOK = NO, finished = NO;
	BOOL wasAway = _away;
	void (^finish)(BOOL) = ^(BOOL reachable) {
		if (finished) return;
		finished = YES;
		if (done) done(reachable);
	};
	[self probe:self.homeURL completion:^(BOOL homeOK) {
		homeDone = YES;
		if (homeOK) {
			[self useServer:self.homeURL away:NO];
			finish(YES);
			return;
		}
		if (!awayDone) return;
		if (awayOK) [self useServer:self.awayURL away:YES];
		WALog(@"choose server: home no, away %@", awayOK ? @"yes" : @"no");
		finish(awayOK);
	}];
	[self probe:self.awayURL completion:^(BOOL ok) {
		awayDone = YES;
		awayOK = ok;
		if (!homeDone && !(ok && wasAway)) return;
		if (finished) return;
		if (ok) [self useServer:self.awayURL away:YES];
		WALog(@"choose server: away %@ (home %@)", ok ? @"yes" : @"no", homeDone ? @"no" : @"still asked");
		finish(ok);
	}];
}

- (void)useServer:(NSString *)base away:(BOOL)away {
	if ([_serverURL isEqualToString:base]) return;
	WALog(@"server: %@", away ? @"away" : @"home");
	_serverURL = [base copy];
	_away = away;
	[[NSUserDefaults standardUserDefaults] setBool:away forKey:@"lastAway"];
	[[NSNotificationCenter defaultCenter] postNotificationName:WAClientServerChangedNotification object:self];
}

- (NSString *)query:(NSDictionary *)params {
	NSMutableArray *parts = [NSMutableArray array];
	for (NSString *key in params) {
		[parts addObject:[NSString stringWithFormat:@"%@=%@", WAEscape(key), WAEscape([params[key] description])]];
	}
	return [parts componentsJoinedByString:@"&"];
}

- (NSMutableURLRequest *)requestFor:(NSString *)path params:(NSDictionary *)params {
	NSString *base = self.serverURL;
	while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
	NSString *url = [base stringByAppendingString:path];
	if (params.count) url = [url stringByAppendingFormat:@"?%@", [self query:params]];
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
		cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
	[req setValue:self.token forHTTPHeaderField:@"X-WA4S-Token"];
	return req;
}

- (void)send:(NSURLRequest *)req completion:(WAJSONBlock)completion {
	[self load:req completion:^(NSData *data, NSInteger code, NSError *error) {
		id json = nil;
		if (!error && data.length) {
			json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
		}
		if (!error && code != 200) {
			NSString *msg = [json isKindOfClass:[NSDictionary class]] ? json[@"error"] : nil;
			if (!msg) msg = code == 401 ? @"Wrong key" : [NSString stringWithFormat:@"Error %ld", (long)code];
			error = [NSError errorWithDomain:@"WA4S" code:code userInfo:@{NSLocalizedDescriptionKey: msg}];
			json = nil;
		}
		completion(json, error);
	}];
}

- (void)get:(NSString *)path params:(NSDictionary *)params completion:(WAJSONBlock)completion {
	[self send:[self requestFor:path params:params] completion:completion];
}

- (void)post:(NSString *)path params:(NSDictionary *)params completion:(WAJSONBlock)completion {
	NSMutableURLRequest *req = [self requestFor:path params:nil];
	req.HTTPMethod = @"POST";
	[req setValue:@"application/x-www-form-urlencoded; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
	req.HTTPBody = [[self query:params] dataUsingEncoding:NSUTF8StringEncoding];
	[self send:req completion:completion];
}

- (void)post:(NSString *)path params:(NSDictionary *)params data:(NSData *)body contentType:(NSString *)type
	completion:(WAJSONBlock)completion {
	NSMutableURLRequest *req = [self requestFor:path params:params];
	req.HTTPMethod = @"POST";
	req.timeoutInterval = 120;
	[req setValue:type forHTTPHeaderField:@"Content-Type"];
	req.HTTPBody = body;
	[self send:req completion:completion];
}

- (NSURLRequest *)mediaRequestForSeq:(long long)seq format:(NSString *)format {
	NSDictionary *params = format ? @{@"seq": @(seq), @"format": format} : @{@"seq": @(seq)};
	NSMutableURLRequest *req = [self requestFor:@"/api/media" params:params];
	req.timeoutInterval = 180; // server converts first
	return req;
}

- (NSURLRequest *)videoRequestForSeq:(long long)seq optimized:(BOOL)small {
	NSMutableDictionary *params = [@{@"seq": @(seq), @"format": @"mp4"} mutableCopy];
	if (small) params[@"optimize"] = @"1";
	NSMutableURLRequest *req = [self requestFor:@"/api/media" params:params];
	req.timeoutInterval = 180; // server converts first
	return req;
}

- (NSURLRequest *)voiceRequestForSeq:(long long)seq {
	NSMutableURLRequest *req = [self requestFor:@"/api/media" params:@{@"seq": @(seq), @"format": @"m4a"}];
	req.timeoutInterval = 90;
	return req;
}

- (NSURLRequest *)fullAvatarRequestFor:(NSString *)jid {
	return [self requestFor:@"/api/avatar" params:@{@"jid": jid, @"full": @"1"}];
}

- (NSURLRequest *)mediaRequestForSeq:(long long)seq {
	NSMutableURLRequest *req = [self requestFor:@"/api/media" params:@{@"seq": @(seq)}];
	req.timeoutInterval = 90;
	return req;
}

#pragma mark - Profile pictures

- (UIImage *)cachedAvatarFor:(NSString *)jid {
	return jid ? [_avatars objectForKey:jid] : nil;
}

- (void)avatarFor:(NSString *)jid completion:(void (^)(UIImage *image))completion {
	if (!jid.length || !self.configured) return;
	UIImage *img = [_avatars objectForKey:jid];
	if (img || [_noAvatar containsObject:jid]) {
		completion(img);
		return;
	}
	NSMutableArray *waiters = _avatarWaiters[jid];
	if (waiters) {
		[waiters addObject:[completion copy]];
		return;
	}
	_avatarWaiters[jid] = [NSMutableArray arrayWithObject:[completion copy]];
	NSMutableURLRequest *req = [self requestFor:@"/api/avatar" params:@{@"jid": jid}];
	[self load:req completion:^(NSData *data, NSInteger code, NSError *error) {
			UIImage *image = code == 200 && data.length ? [UIImage imageWithData:data] : nil;
			if (image) [self->_avatars setObject:image forKey:jid];
			else if (code == 404) [self->_noAvatar addObject:jid];
			NSArray *list = self->_avatarWaiters[jid];
			[self->_avatarWaiters removeObjectForKey:jid];
			for (void (^block)(UIImage *) in list) block(image);
		}];
}

- (void)setOnline:(BOOL)online {
	if (!self.configured) return;
	[self post:@"/api/presence" params:@{@"state": online ? @"available" : @"unavailable"} completion:^(id json, NSError *error) {}];
}

- (long long)upd {
	return _upd;
}

- (void)noteUpd:(long long)upd {
	if (upd <= _upd) return;
	_upd = upd;
	// persist so a bg relaunch doesn't re-notify
	[[NSUserDefaults standardUserDefaults] setObject:@(upd) forKey:@"upd"];
}

#pragma mark - Long poll

- (void)startUpdatesFrom:(long long)upd {
	[self noteUpd:upd];
	if (_polling) return;
	_polling = YES;
	_pollGeneration++;
	[self pollWithGeneration:_pollGeneration];
}

- (void)stopUpdates {
	_polling = NO;
	_pollGeneration++;
}

- (void)pollWithGeneration:(NSUInteger)gen {
	if (!_polling || gen != _pollGeneration) return;
	NSMutableURLRequest *req = [self requestFor:@"/api/updates" params:@{@"since": @(_upd), @"wait": @25}];
	req.timeoutInterval = 45;
	[self send:req completion:^(id json, NSError *error) {
		if (gen != self->_pollGeneration) return;
		if (error || ![json isKindOfClass:[NSDictionary class]]) {
			// failed twice, maybe network changed
			if (++self->_pollErrors >= 2) {
				self->_pollErrors = 0;
				[self chooseServer:nil];
			}
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
				[self pollWithGeneration:gen];
			});
			return;
		}
		self->_pollErrors = 0;
		[self noteUpd:[json[@"upd"] longLongValue]];
		NSArray *messages = json[@"messages"];
		NSArray *presence = [json[@"presence"] isKindOfClass:[NSArray class]] ? json[@"presence"] : @[];
		BOOL chatsChanged = [json[@"chatsChanged"] boolValue];
		NSDictionary *call = [json[@"call"] isKindOfClass:[NSDictionary class]] ? json[@"call"] : nil;
		if (messages.count || chatsChanged || presence.count || call) {
			NSMutableDictionary *info = [@{@"messages": messages ?: @[], @"chatsChanged": @(chatsChanged), @"presence": presence} mutableCopy];
			if (call) info[@"call"] = call;
			[[NSNotificationCenter defaultCenter] postNotificationName:WAClientUpdatesNotification object:self userInfo:info];
		}
		[self pollWithGeneration:gen];
	}];
}

@end
