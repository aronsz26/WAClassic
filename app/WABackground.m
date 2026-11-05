#import "WABackground.h"
#import "WAClient.h"
#import "WAUtil.h"
#import "WACall.h"
#import "WAPrefs.h"

NSString *WANotificationText(NSDictionary *m) {
	NSString *kind = m[@"kind"], *text = m[@"text"];
	if ([kind isEqualToString:@"audio"]) text = @"Audio";
	else if (![kind isEqualToString:@"text"]) text = text.length ? [NSString stringWithFormat:@"%@: %@", WAKindLabel(kind), text] : WAKindLabel(kind);
	NSString *chatName = m[@"chatName"] ?: @"";
	BOOL group = [m[@"chat"] hasSuffix:@"@g.us"];
	if (group && [m[@"name"] length]) return [NSString stringWithFormat:@"%@ @ %@: %@", m[@"name"], chatName, text];
	return [NSString stringWithFormat:@"%@: %@", chatName, text];
}

@implementation WABackground {
	NSInputStream *_in;
	NSOutputStream *_out;
	NSMutableData *_response;
	NSData *_request;
	BOOL _running, _sent, _tls;
	NSDate *_openedAt, *_lastError;
	UIBackgroundTaskIdentifier _task;
	BOOL _choosing;
}

+ (WABackground *)shared {
	static WABackground *bg;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ bg = [[WABackground alloc] init]; });
	return bg;
}

- (void)serverChanged {
	if (_running) [self reconnect];
}

- (void)start {
	WALog(@"background: start");
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(serverChanged)
			name:WAClientServerChangedNotification object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(networkChanged)
			name:WAClientNetworkChangedNotification object:nil];
	});
	_running = YES;
	UIApplication *app = [UIApplication sharedApplication];
	// keepalive, at least every 10 min
	[app setKeepAliveTimeout:600 handler:^{
		WALog(@"keep-alive (socket %@, %.0f s old)", self->_in ? @"open" : @"none", -[self->_openedAt timeIntervalSinceNow]);
		if (!self->_in || !self->_sent || -[self->_openedAt timeIntervalSinceNow] > 540) [self chooseAndReconnect];
	}];
	[self reconnect];
}

- (void)stop {
	WALog(@"background: stop");
	_running = NO;
	[[UIApplication sharedApplication] clearKeepAliveTimeout];
	[self close];
}

// network changed, reconnect now instead of waiting for keepalive
- (void)networkChanged {
	if (_running) [self chooseAndReconnect];
}

// home <-> away might have changed. own bg task, the shared one ends too early
- (void)chooseAndReconnect {
	if (_choosing) return;
	_choosing = YES;
	UIApplication *app = [UIApplication sharedApplication];
	__block UIBackgroundTaskIdentifier task = [app beginBackgroundTaskWithExpirationHandler:^{
		[app endBackgroundTask:task];
		task = UIBackgroundTaskInvalid;
	}];
	[[WAClient shared] chooseServer:^(BOOL reachable) {
		self->_choosing = NO;
		[self reconnect];
		if (task != UIBackgroundTaskInvalid) [app endBackgroundTask:task];
		task = UIBackgroundTaskInvalid;
	}];
}

- (void)close {
	for (NSStream *s in @[_in ?: (id)[NSNull null], _out ?: (id)[NSNull null]]) {
		if ([s isKindOfClass:[NSNull class]]) continue;
		s.delegate = nil;
		[s close];
		[s removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
	}
	_in = nil;
	_out = nil;
}

- (void)reconnect {
	[self close];
	WAClient *client = [WAClient shared];
	if (!_running || !client.configured) return;
	NSURL *url = [NSURL URLWithString:client.serverURL];
	if (!url.host) return;
	BOOL tls = [url.scheme isEqualToString:@"https"];
	int port = url.port ? url.port.intValue : (tls ? 443 : 80);
	CFReadStreamRef readStream = NULL;
	CFWriteStreamRef writeStream = NULL;
	CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)url.host, port, &readStream, &writeStream);
	if (!readStream || !writeStream) {
		WALog(@"reconnect: no streams");
		return;
	}
	WALog(@"reconnect since=%lld", client.upd);
	// stay awake until the request is written
	[self beginTask];
	_in = CFBridgingRelease(readStream);
	_out = CFBridgingRelease(writeStream);
	// voip socket
	[_in setProperty:NSStreamNetworkServiceTypeVoIP forKey:NSStreamNetworkServiceType];
	[_out setProperty:NSStreamNetworkServiceTypeVoIP forKey:NSStreamNetworkServiceType];
	if (tls) {
		// self signed, we check the pin ourselves
		NSDictionary *ssl = @{(__bridge id)kCFStreamSSLValidatesCertificateChain: @NO,
			(__bridge id)kCFStreamSSLLevel: (__bridge id)kCFStreamSocketSecurityLevelNegotiatedSSL};
		CFReadStreamSetProperty(readStream, kCFStreamPropertySSLSettings, (__bridge CFDictionaryRef)ssl);
		CFWriteStreamSetProperty(writeStream, kCFStreamPropertySSLSettings, (__bridge CFDictionaryRef)ssl);
	}
	_tls = tls;
	NSString *path = [NSString stringWithFormat:@"/api/updates?since=%lld&wait=900&only=incoming", client.upd];
	_request = [[NSString stringWithFormat:@"GET %@ HTTP/1.0\r\nHost: %@:%d\r\nX-WA4S-Token: %@\r\n\r\n",
		path, url.host, port, client.token] dataUsingEncoding:NSUTF8StringEncoding];
	_response = [NSMutableData data];
	_sent = NO;
	_openedAt = [NSDate date];
	for (NSStream *s in @[_in, _out]) {
		s.delegate = self;
		[s scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
		[s open];
	}
}

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)event {
	switch (event) {
		case NSStreamEventOpenCompleted:
			if (stream == _in) WALog(@"connected");
			break;
		case NSStreamEventHasSpaceAvailable:
			if (stream == _out && !_sent) {
				if (_tls) {
					SecTrustRef trust = (__bridge SecTrustRef)[_out propertyForKey:(__bridge NSString *)kCFStreamPropertySSLPeerTrust];
					if (!WAPinMatches(trust, [WAClient shared].pin)) {
						WALog(@"background: certificate does not match the pin");
						[self close];
						[self endTask];
						break;
					}
				}
				_sent = YES;
				NSInteger written = [_out write:_request.bytes maxLength:_request.length];
				WALog(@"request sent (%ld bytes)", (long)written);
				[self endTask];
			}
			break;
		case NSStreamEventHasBytesAvailable: {
			[self beginTask];
			uint8_t buf[4096];
			NSInteger n;
			while ([_in hasBytesAvailable] && (n = [_in read:buf maxLength:sizeof(buf)]) > 0) {
				[_response appendBytes:buf length:n];
			}
			break;
		}
		case NSStreamEventEndEncountered:
			WALog(@"answer: %lu bytes", (unsigned long)_response.length);
			[self beginTask];
			[self handleResponse];
			[self close];
			// end the task only after "request sent", the 4s got suspended before sending
			[self reconnect];
			if (!_in) [self endTask];
			break;
		case NSStreamEventErrorOccurred: {
			WALog(@"stream error: %@", stream.streamError);
			[self close];
			// retry right away (max every 30s), else keepalive does it
			if (!_lastError || -[_lastError timeIntervalSinceNow] > 30) {
				_lastError = [NSDate date];
				[self chooseAndReconnect];
			}
			[self endTask];
			break;
		}
		default:
			break;
	}
}

- (void)beginTask {
	if (_task && _task != UIBackgroundTaskInvalid) return;
	_task = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{ [self endTask]; }];
}

- (void)endTask {
	if (_task && _task != UIBackgroundTaskInvalid) [[UIApplication sharedApplication] endBackgroundTask:_task];
	_task = UIBackgroundTaskInvalid;
}

- (void)handleResponse {
	NSData *sep = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
	NSRange r = [_response rangeOfData:sep options:0 range:NSMakeRange(0, _response.length)];
	if (r.location == NSNotFound) return;
	NSString *head = [[NSString alloc] initWithData:[_response subdataWithRange:NSMakeRange(0, r.location)] encoding:NSUTF8StringEncoding];
	if (![head hasPrefix:@"HTTP/1.1 200"] && ![head hasPrefix:@"HTTP/1.0 200"]) {
		WALog(@"answer not OK: %@", [head componentsSeparatedByString:@"\r\n"].firstObject);
		return;
	}
	NSData *body = [_response subdataWithRange:NSMakeRange(NSMaxRange(r), _response.length - NSMaxRange(r))];
	NSDictionary *json = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
	if (![json isKindOfClass:[NSDictionary class]]) return;
	WAClient *client = [WAClient shared];
	[client noteUpd:[json[@"upd"] longLongValue]];
	UIApplication *app = [UIApplication sharedApplication];
	NSInteger unread = [json[@"unreadTotal"] integerValue];
	app.applicationIconBadgeNumber = unread;
	if ([json[@"call"] isKindOfClass:[NSDictionary class]]) [[WACall shared] notifyRinging:json[@"call"]];

	long long now = (long long)[[NSDate date] timeIntervalSince1970];
	NSInteger shown = 0;
	for (NSDictionary *m in json[@"messages"]) {
		if ([m[@"fromMe"] boolValue] || [m[@"ts"] longLongValue] < now - 3600 || shown >= 5) continue;
		if ([m[@"kind"] isEqualToString:@"call"]) continue; // calls have their own notifs
		// notification settings
		BOOL group = [m[@"chat"] hasSuffix:@"@g.us"];
		if (!WAPrefBool(group ? WAPrefGroupAlerts : WAPrefMessageAlerts)) continue;
		UILocalNotification *n = [[UILocalNotification alloc] init];
		n.alertBody = WAPrefBool(WAPrefShowPreview) ? WANotificationText(m)
			: [NSString stringWithFormat:@"Message from %@", m[@"chatName"] ?: @"WhatsApp"];
		n.alertAction = @"Reply";
		n.soundName = WASoundFile(WAPrefString(group ? WAPrefGroupSound : WAPrefMessageSound));
		n.applicationIconBadgeNumber = unread;
		n.userInfo = @{@"chat": m[@"chat"] ?: @""};
		[app presentLocalNotificationNow:n];
		WALog(@"notification shown");
		shown++;
	}
}

@end
