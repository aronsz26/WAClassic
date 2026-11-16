#import <CommonCrypto/CommonDigest.h>
#import <SystemConfiguration/SystemConfiguration.h>
#include <string.h>
#import "WAClient.h"
#import "WAUtil.h"
#import "WADiag.h"
#import "WATLSFix.h"
#import "WAPrefs.h"
#ifdef WA_DEV
#import "dev/WADev.h"
#endif

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
#ifdef WA_DEV
@property (nonatomic) NSUInteger sentBytes;
#endif
@end

@implementation WAConnection

static NSMutableSet *running;

+ (void)load:(NSURLRequest *)request pin:(NSString *)pin completion:(void (^)(NSData *, NSInteger, NSError *))completion {
	if (!running) running = [NSMutableSet set];
	WAConnection *c = [[WAConnection alloc] init];
	c.pin = pin;
	c.completion = completion;
	c.data = [NSMutableData data];
#ifdef WA_DEV
	c.sentBytes = request.HTTPBody.length;
#endif
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
#ifdef WA_DEV
	WADevCountRequest(self.data.length, self.sentBytes, self.status >= 400);
#endif
	self.completion(self.data, self.status, nil);
	[running removeObject:self];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
#ifdef WA_DEV
	WADevCountRequest(0, self.sentBytes, YES);
#endif
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
	NSMutableDictionary *_mediaWaiters;
}

static NSString *WAMediaCacheDirectory(void) {
	return [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
		stringByAppendingPathComponent:@"MediaCache"];
}

static NSString *WAMediaCacheCategory(NSURLRequest *request) {
	NSString *format = nil;
	for (NSString *part in [request.URL.query componentsSeparatedByString:@"&"]) {
		if ([part hasPrefix:@"format="]) { format = [part substringFromIndex:7]; break; }
	}
	if ([format isEqualToString:@"m4a"]) return @"audio";
	if ([format isEqualToString:@"mp4"]) return @"video";
	return @"images";
}

static unsigned long long WAMediaCacheLimit(NSString *category) {
	if ([category isEqualToString:@"audio"]) return 20ULL * 1024 * 1024;
	if ([category isEqualToString:@"video"]) return 128ULL * 1024 * 1024;
	return 30ULL * 1024 * 1024;
}

static NSString *WAMediaCachePath(NSURLRequest *request, NSString *token) {
	NSString *category = WAMediaCacheCategory(request);
	NSString *identity = [NSString stringWithFormat:@"%@\n%@", request.URL.absoluteString ?: @"", token ?: @""];
	unsigned char digest[CC_SHA256_DIGEST_LENGTH];
	CC_SHA256(identity.UTF8String, (CC_LONG)strlen(identity.UTF8String), digest);
	NSMutableString *key = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
	for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [key appendFormat:@"%02x", digest[i]];
	NSString *extension = [category isEqualToString:@"audio"] ? @"m4a" : ([category isEqualToString:@"video"] ? @"mp4" : @"img");
	return [[[WAMediaCacheDirectory() stringByAppendingPathComponent:category] stringByAppendingPathComponent:key]
		stringByAppendingPathExtension:extension];
}

static void WAPruneMediaCache(NSString *directory, unsigned long long limit) {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSArray *files = [fm contentsOfDirectoryAtPath:directory error:NULL];
	NSMutableArray *entries = [NSMutableArray array];
	unsigned long long total = 0;
	for (NSString *name in files) {
		NSString *path = [directory stringByAppendingPathComponent:name];
		NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
		if (![attrs[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
		unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
		total += size;
		[entries addObject:@{ @"path": path, @"size": @(size), @"date": attrs[NSFileModificationDate] ?: [NSDate distantPast] }];
	}
	[entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
		return [a[@"date"] compare:b[@"date"]];
	}];
	for (NSDictionary *entry in entries) {
		if (total <= limit) break;
		[fm removeItemAtPath:entry[@"path"] error:NULL];
		total -= [entry[@"size"] unsignedLongLongValue];
	}
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
		_mediaWaiters = [NSMutableDictionary dictionary];
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

static BOOL gNetworkDown;

- (BOOL)networkUp {
	return !gNetworkDown;
}

// network changed, recheck
static void NetworkChanged(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info) {
	WALog(@"network changed (flags %x)", flags);
	gNetworkDown = !(flags & kSCNetworkReachabilityFlagsReachable);
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
		completion([NSError errorWithDomain:@"WA4S" code:0 userInfo:@{NSLocalizedDescriptionKey: WAL(@"Please enter the address of your bridge.")}]);
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
			NSString *msg = error ? WAL(@"The bridge could not be reached. Check the address and that this iPhone is on the same Wi-Fi.")
				: status == 403 ? WAL(@"Wrong or expired setup code. Restart the bridge for a new one.")
				: [NSString stringWithFormat:WAL(@"This is not a WA Classic bridge (error %ld)."), (long)status];
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
	if ([request.HTTPMethod.uppercaseString isEqualToString:@"POST"] || ![request.URL.path isEqualToString:@"/api/media"]) {
		[WAConnection load:request pin:self.pin completion:completion];
		return;
	}
	NSString *path = WAMediaCachePath(request, self.token);
	@synchronized (self) {
		NSMutableArray *waiters = _mediaWaiters[path];
		if (waiters) { [waiters addObject:[completion copy]]; return; }
		_mediaWaiters[path] = [NSMutableArray arrayWithObject:[completion copy]];
	}
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSData *cached = [NSData dataWithContentsOfFile:path];
		if (cached.length) {
			[[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: [NSDate date]} ofItemAtPath:path error:NULL];
			dispatch_async(dispatch_get_main_queue(), ^{ [self finishMediaCacheKey:path data:cached status:200 error:nil]; });
			return;
		}
		dispatch_async(dispatch_get_main_queue(), ^{ [WAConnection load:request pin:self.pin completion:^(NSData *data, NSInteger status, NSError *error) {
			if (!error && status == 200 && data.length) {
				NSString *directory = [path stringByDeletingLastPathComponent];
				unsigned long long limit = WAMediaCacheLimit(WAMediaCacheCategory(request));
				if (data.length <= limit) {
					dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
						NSFileManager *fm = [NSFileManager defaultManager];
						[fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
						[data writeToFile:path atomically:YES];
						WAPruneMediaCache(directory, limit);
						dispatch_async(dispatch_get_main_queue(), ^{ [self finishMediaCacheKey:path data:data status:status error:error]; });
					});
					return;
				}
			}
			[self finishMediaCacheKey:path data:data status:status error:error];
		}]; });
	});
}

- (NSString *)cachedMediaPathForRequest:(NSURLRequest *)request {
	if (![request.URL.path isEqualToString:@"/api/media"]) return nil;
	NSString *path = WAMediaCachePath(request, self.token);
	if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
	[[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: [NSDate date]} ofItemAtPath:path error:NULL];
	return path;
}

- (void)finishMediaCacheKey:(NSString *)key data:(NSData *)data status:(NSInteger)status error:(NSError *)error {
	NSArray *waiters;
	@synchronized (self) {
		waiters = [_mediaWaiters[key] copy];
		[_mediaWaiters removeObjectForKey:key];
	}
	for (void (^waiter)(NSData *, NSInteger, NSError *) in waiters) waiter(data, status, error);
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
			if (!msg) msg = code == 401 ? WAL(@"Wrong key") : [NSString stringWithFormat:WAL(@"Error %ld"), (long)code];
			error = [NSError errorWithDomain:@"WA4S" code:code userInfo:@{NSLocalizedDescriptionKey: msg}];
			json = nil;
		}
		if (error) [self recordError:error request:req status:code];
		completion(json, error);
	}];
}

// e.g. "sendimage -1200 tls cell" for the diagnostics, only counted if the user said yes
- (void)recordError:(NSError *)error request:(NSURLRequest *)req status:(NSInteger)status {
	NSString *path = [req.URL.path stringByReplacingOccurrencesOfString:@"/api/" withString:@""];
	if ([path isEqualToString:@"updates"] || error.code == NSURLErrorCancelled) return; // long poll timeouts are normal
	NSString *what = status >= 400 ? [NSString stringWithFormat:@"%ld", (long)status] : [NSString stringWithFormat:@"%ld", (long)error.code];
	NSString *code = [NSString stringWithFormat:@"%@ %@ %@ %@", path, what,
		[req.URL.scheme isEqualToString:@"https"] ? @"tls" : @"http", WAOnWiFi() ? @"wifi" : @"cell"];
	// upload size in steps, only with the 1.0.3 consent
	NSUInteger size = req.HTTPBody.length;
	if (size > 0 && [WADiag shared].extended)
		code = [code stringByAppendingString:size < 100000 ? @" <100KB" : size < 1000000 ? @" <1MB" : size < 5000000 ? @" <5MB" : @" 5MB+"];
	[[WADiag shared] record:code];
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

// TLSFix's openssl breaks writes over ~250 KB ("SSL error", the bridge sees the upload end early).
// with it, big uploads over tls go to /api/chunk in pieces, then the request with ?chunk=id and no body
static const NSUInteger kPiece = 128 * 1024;

- (void)post:(NSString *)path params:(NSDictionary *)params data:(NSData *)body contentType:(NSString *)type
	completion:(WAJSONBlock)completion {
	if (WATLSFixActive() && body.length > kPiece && [self.serverURL hasPrefix:@"https"]) {
		CFUUIDRef ref = CFUUIDCreate(NULL);
		NSString *uid = (__bridge_transfer NSString *)CFUUIDCreateString(NULL, ref);
		CFRelease(ref);
		[self sendPieceOf:body id:uid offset:0 retried:NO done:^(NSError *error) {
			if (error.code == 404) { // bridge without /api/chunk: the old way
				[self postWhole:path params:params data:body contentType:type completion:completion];
				return;
			}
			if (error) {
				completion(nil, error);
				return;
			}
			NSMutableDictionary *p = [params mutableCopy] ?: [NSMutableDictionary dictionary];
			p[@"chunk"] = uid;
			[self postWhole:path params:p data:[NSData data] contentType:type completion:completion];
		}];
		return;
	}
	[self postWhole:path params:params data:body contentType:type completion:completion];
}

- (void)sendPieceOf:(NSData *)body id:(NSString *)uid offset:(NSUInteger)offset retried:(BOOL)retried done:(void (^)(NSError *error))done {
	if (offset >= body.length) {
		done(nil);
		return;
	}
	NSData *piece = [body subdataWithRange:NSMakeRange(offset, MIN(kPiece, body.length - offset))];
	NSMutableURLRequest *req = [self requestFor:@"/api/chunk" params:@{@"id": uid, @"off": @(offset)}];
	req.HTTPMethod = @"POST";
	req.timeoutInterval = 60;
	[req setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
	req.HTTPBody = piece;
	[self send:req completion:^(id json, NSError *error) {
		if (error && error.code != 404 && !retried) {
			// the bridge keeps what it has, try this piece once more
			[self sendPieceOf:body id:uid offset:offset retried:YES done:done];
			return;
		}
		if (error) {
			done(error);
			return;
		}
		[self sendPieceOf:body id:uid offset:offset + piece.length retried:NO done:done];
	}];
}

- (void)postWhole:(NSString *)path params:(NSDictionary *)params data:(NSData *)body contentType:(NSString *)type
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

static NSTimeInterval const kAvatarCacheLifetime = 24 * 60 * 60;
static unsigned long long const kAvatarCacheLimit = 5 * 1024 * 1024;

- (NSString *)avatarCachePathFor:(NSString *)jid missing:(BOOL)missing {
	NSString *identity = [NSString stringWithFormat:@"%@\n%@\n%@", self.serverURL ?: @"", self.token ?: @"", jid ?: @""];
	unsigned char digest[CC_SHA256_DIGEST_LENGTH];
	CC_SHA256(identity.UTF8String, (CC_LONG)strlen(identity.UTF8String), digest);
	NSMutableString *key = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
	for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [key appendFormat:@"%02x", digest[i]];
	NSString *directory = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
		stringByAppendingPathComponent:@"ProfilePictures"];
	[[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
	return [directory stringByAppendingPathComponent:[key stringByAppendingString:missing ? @".none" : @".jpg"]];
}

- (BOOL)avatarCachePath:(NSString *)path isFresh:(BOOL *)fresh {
	NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
	NSDate *date = attrs[NSFileModificationDate];
	if (!date) return NO;
	if (fresh) *fresh = [[NSDate date] timeIntervalSinceDate:date] < kAvatarCacheLifetime;
	return YES;
}

- (void)pruneAvatarCacheKeeping:(NSString *)recentPath {
	NSString *directory = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
		stringByAppendingPathComponent:@"ProfilePictures"];
	NSArray *paths = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:NULL];
	NSMutableArray *entries = [NSMutableArray array];
	unsigned long long total = 0;
	for (NSString *name in paths) {
		NSString *path = [directory stringByAppendingPathComponent:name];
		NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
		if (!attrs) continue;
		unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
		total += size;
		[entries addObject:@{ @"path": path, @"date": attrs[NSFileModificationDate] ?: [NSDate distantPast], @"size": @(size) }];
	}
	[entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
		return [a[@"date"] compare:b[@"date"]];
	}];
	for (NSDictionary *entry in entries) {
		NSString *path = entry[@"path"];
		if (total <= kAvatarCacheLimit) break;
		if ([path isEqualToString:recentPath]) continue;
		if ([[NSFileManager defaultManager] removeItemAtPath:path error:NULL]) total -= [entry[@"size"] unsignedLongLongValue];
	}
}

- (UIImage *)cachedAvatarFor:(NSString *)jid {
	if (!jid.length) return nil;
	UIImage *image = [_avatars objectForKey:jid];
	if (image) return image;
	NSData *data = [NSData dataWithContentsOfFile:[self avatarCachePathFor:jid missing:NO]];
	image = data.length ? [UIImage imageWithData:data] : nil;
	if (image) [_avatars setObject:image forKey:jid];
	return image;
}

- (void)avatarFor:(NSString *)jid completion:(void (^)(UIImage *image))completion {
	if (!jid.length || !self.configured) return;
	NSString *file = [self avatarCachePathFor:jid missing:NO];
	NSString *none = [self avatarCachePathFor:jid missing:YES];
	BOOL freshImage = NO, freshNone = NO;
	UIImage *img = [self cachedAvatarFor:jid];
	BOOL hasImage = [self avatarCachePath:file isFresh:&freshImage];
	BOOL hasNone = [self avatarCachePath:none isFresh:&freshNone];
	if (hasImage && freshImage && img) {
		completion(img);
		return;
	}
	if (hasNone && freshNone) {
		completion(nil);
		return;
	}
	NSString *waiterKey = [NSString stringWithFormat:@"%@\n%@", self.serverURL ?: @"", jid];
	NSMutableArray *waiters = _avatarWaiters[waiterKey];
	if (waiters) {
		[waiters addObject:[completion copy]];
		return;
	}
	_avatarWaiters[waiterKey] = [NSMutableArray arrayWithObject:[completion copy]];
	NSMutableURLRequest *req = [self requestFor:@"/api/avatar" params:@{@"jid": jid}];
	[self load:req completion:^(NSData *data, NSInteger code, NSError *error) {
			UIImage *image = code == 200 && data.length ? [UIImage imageWithData:data] : nil;
			if (image) {
				[self->_avatars setObject:image forKey:jid];
				[data writeToFile:file atomically:YES];
				[self pruneAvatarCacheKeeping:file];
				[[NSFileManager defaultManager] removeItemAtPath:none error:NULL];
			} else if (code == 404) {
				[[NSFileManager defaultManager] removeItemAtPath:file error:NULL];
				[[NSData data] writeToFile:none atomically:YES];
				[self->_avatars removeObjectForKey:jid];
			}
			NSArray *list = self->_avatarWaiters[waiterKey];
			[self->_avatarWaiters removeObjectForKey:waiterKey];
			for (void (^block)(UIImage *) in list) block(image);
		}];
}

- (void)forgetAvatar:(NSString *)jid {
	if (!jid.length) return;
	[_avatars removeObjectForKey:jid];
	[[NSFileManager defaultManager] removeItemAtPath:[self avatarCachePathFor:jid missing:NO] error:NULL];
	[[NSFileManager defaultManager] removeItemAtPath:[self avatarCachePathFor:jid missing:YES] error:NULL];
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
