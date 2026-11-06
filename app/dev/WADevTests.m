#import <mach/mach.h>
#import "WADev.h"
#import "../WAClient.h"
#import "../WACall.h"
#import "../WAAssets.h"
#import "../WASettingsPages.h"
#import "../WAUtil.h"

// self tests: only look, nothing other iphones on the bridge would notice.
// results go to dev-tests.txt too. numbers only, no names and no chat content

typedef enum { WADevWaiting, WADevOK, WADevWarn, WADevFail } WADevResult;
typedef void (^WADevReport)(WADevResult result, NSString *detail);
typedef void (^WADevRun)(WADevReport report);

@interface WADevTest : NSObject
@property (nonatomic, copy) NSString *name, *detail;
@property (nonatomic, copy) WADevRun run;
@property (nonatomic) WADevResult result;
@property (nonatomic) int ms;
@property (nonatomic) NSUInteger attempt;
@end

@implementation WADevTest
@end

static NSString *HTTPText(NSInteger status, NSError *error) {
	return error ? error.localizedDescription : [NSString stringWithFormat:@"HTTP %ld", (long)status];
}

static NSMutableURLRequest *Request(NSString *base, NSString *path, NSString *token, NSTimeInterval timeout) {
	while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:path]]
		cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:timeout];
	[req setValue:token forHTTPHeaderField:@"X-WA4S-Token"];
	return req;
}

static WADevTest *Test(NSString *name, WADevRun run) {
	WADevTest *t = [[WADevTest alloc] init];
	t.name = name;
	t.run = run;
	return t;
}

// one address on its own, the one not in use may be down
static WADevRun Address(BOOL home) {
	return ^(WADevReport report) {
		WAClient *c = [WAClient shared];
		NSString *base = home ? c.homeURL : c.awayURL;
		if (!base.length) return report(WADevOK, @"not set");
		if (home && [base isEqualToString:c.awayURL]) return report(WADevOK, @"same as away");
		BOOL inUse = [base isEqualToString:c.serverURL];
		[c load:Request(base, @"/api/status", c.token, 6) completion:^(NSData *data, NSInteger status, NSError *error) {
			if (status == 200) report(WADevOK, inUse ? @"in use" : @"reachable, not in use");
			else report(inUse ? WADevFail : WADevWarn, HTTPText(status, error));
		}];
	};
}

static NSArray *MakeTests(void) {
	WAClient *c = [WAClient shared];
	return @[
		Test(@"Settings", ^(WADevReport report) {
			if (!c.configured) return report(WADevFail, @"no address or key");
			BOOL https = [c.serverURL hasPrefix:@"https:"];
			if (https && c.pin.length != 64) return report(WADevFail, @"https without a pin");
			report(WADevOK, https ? @"https, pinned" : @"http");
		}),
		Test(@"Bridge Reachable", ^(WADevReport report) {
			[c get:@"/api/status" params:nil completion:^(id json, NSError *error) {
				if (error) return report(WADevFail, error.localizedDescription);
				report(WADevOK, [NSString stringWithFormat:@"bridge %@", json[@"version"] ?: @"without version"]);
			}];
		}),
		Test(@"Home Address", Address(YES)),
		Test(@"Away Address", Address(NO)),
		Test(@"Linked and Connected", ^(WADevReport report) {
			[c get:@"/api/status" params:nil completion:^(id json, NSError *error) {
				if (error) return report(WADevFail, error.localizedDescription);
				if (![json[@"paired"] boolValue]) return report(WADevFail, @"bridge not linked");
				if (![json[@"connected"] boolValue]) return report(WADevFail, @"bridge can't reach WhatsApp");
				report(WADevOK, [json[@"loggedIn"] boolValue] ? @"logged in" : @"connected, not logged in yet");
			}];
		}),
		Test(@"Bridge Version", ^(WADevReport report) {
			[c get:@"/api/status" params:nil completion:^(id json, NSError *error) {
				if (error) return report(WADevFail, error.localizedDescription);
				NSString *bridge = json[@"version"], *app = [NSBundle mainBundle].infoDictionary[@"CFBundleVersion"];
				if ([bridge isEqualToString:@"dev"]) return report(WADevOK, @"own bridge build");
				BOOL ok = bridge.length && [bridge compare:app options:NSNumericSearch] != NSOrderedAscending;
				report(ok ? WADevOK : WADevWarn, [NSString stringWithFormat:@"bridge %@, app %@", bridge ?: @"?", app]);
			}];
		}),
		Test(@"Wrong Key Refused", ^(WADevReport report) {
			[c load:Request(c.serverURL, @"/api/status", @"wrong-key", 8) completion:^(NSData *data, NSInteger status, NSError *error) {
				if (status == 401) report(WADevOK, @"401");
				else report(WADevFail, status == 200 ? @"bridge let it in" : HTTPText(status, error));
			}];
		}),
		Test(@"Chat List", ^(WADevReport report) {
			[c get:@"/api/chats" params:nil completion:^(id json, NSError *error) {
				if (error) return report(WADevFail, error.localizedDescription);
				NSArray *chats = json[@"chats"];
				if (![chats isKindOfClass:[NSArray class]]) return report(WADevFail, @"no list in the answer");
				report(chats.count ? WADevOK : WADevWarn, [NSString stringWithFormat:@"%lu chats", (unsigned long)chats.count]);
			}];
		}),
		Test(@"Contacts", ^(WADevReport report) {
			[c get:@"/api/contacts" params:@{@"about": @"0"} completion:^(id json, NSError *error) {
				if (error) return report(WADevFail, error.localizedDescription);
				NSArray *list = json[@"contacts"];
				if (![list isKindOfClass:[NSArray class]]) return report(WADevFail, @"no list in the answer");
				report(list.count ? WADevOK : WADevWarn, [NSString stringWithFormat:@"%lu contacts", (unsigned long)list.count]);
			}];
		}),
		Test(@"Long Poll", ^(WADevReport report) {
			NSMutableURLRequest *req = [c requestFor:@"/api/updates" params:@{@"since": @(c.upd), @"wait": @2}];
			req.timeoutInterval = 10;
			[c load:req completion:^(NSData *data, NSInteger status, NSError *error) {
				id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
				if (status == 200 && json[@"upd"]) report(WADevOK, @"answered");
				else report(WADevFail, HTTPText(status, error));
			}];
		}),
		Test(@"Own Photo", ^(WADevReport report) {
			[c get:@"/api/status" params:nil completion:^(id json, NSError *error) {
				if (![json[@"jid"] length]) return report(WADevWarn, @"not linked");
				[c load:[c requestFor:@"/api/avatar" params:@{@"jid": json[@"jid"]}] completion:^(NSData *data, NSInteger status, NSError *err) {
					if (status == 404) return report(WADevOK, @"no photo set");
					UIImage *image = status == 200 ? [UIImage imageWithData:data] : nil;
					if (image) report(WADevOK, [NSString stringWithFormat:@"%.0f×%.0f", image.size.width, image.size.height]);
					else report(WADevFail, status == 200 ? @"not an image" : HTTPText(status, err));
				}];
			}];
		}),
		Test(@"Classic Look Files", ^(WADevReport report) {
			[c get:@"/api/assets" params:nil completion:^(id json, NSError *error) {
				NSArray *files = [json isKindOfClass:[NSDictionary class]] ? json[@"files"] : nil;
				if (![files isKindOfClass:[NSArray class]]) return report(WADevWarn, error.localizedDescription ?: @"bridge has none yet");
				NSUInteger missing = 0;
				NSFileManager *fm = [NSFileManager defaultManager];
				for (NSDictionary *file in files) {
					NSDictionary *attrs = [fm attributesOfItemAtPath:WAAssetPath(file[@"name"]) error:NULL];
					if (!attrs || attrs.fileSize != [file[@"size"] unsignedLongLongValue]) missing++;
				}
				report(missing ? WADevWarn : WADevOK, missing ? [NSString stringWithFormat:@"%lu of %lu missing", (unsigned long)missing, (unsigned long)files.count]
					: [NSString stringWithFormat:@"all %lu here", (unsigned long)files.count]);
			}];
		}),
		Test(@"Call State", ^(WADevReport report) {
			[c get:@"/api/call/state" params:nil completion:^(id json, NSError *error) {
				if (error || ![json isKindOfClass:[NSDictionary class]]) return report(WADevFail, error.localizedDescription ?: @"bad answer");
				report(WADevOK, [json[@"state"] length] ? json[@"state"] : @"no call");
			}];
		}),
		Test(@"Call Screen Tweak", ^(WADevReport report) {
			if (![WACall systemCallScreen]) return report(WADevFail, @"not installed");
			// last line it wrote when springboard loaded it
			NSString *log = [NSString stringWithContentsOfFile:[WADevFolder stringByAppendingPathComponent:@"callscreen-log.txt"] encoding:NSUTF8StringEncoding error:NULL];
			NSRange r = [log rangeOfString:@"VoIP relaunch hook " options:NSBackwardsSearch];
			if (r.location == NSNotFound) return report(WADevWarn, @"no load line in its log");
			NSString *line = [[log substringFromIndex:r.location] componentsSeparatedByString:@"\n"][0];
			BOOL ok = [line rangeOfString:@"hook 1, banner hook 1"].location != NSNotFound;
			report(ok ? WADevOK : WADevWarn, ok ? @"loaded, hooks in place" : line);
		}),
		Test(@"Data Folder", ^(WADevReport report) {
			NSString *path = [WADevFolder stringByAppendingPathComponent:@".dev-write-test"];
			BOOL ok = [@"x" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
			[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
			report(ok ? WADevOK : WADevFail, ok ? @"writable" : @"can't write");
		}),
		Test(@"Disk Space", ^(WADevReport report) {
			NSDictionary *fs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:@"/var/mobile" error:NULL];
			unsigned long long mb = [fs[NSFileSystemFreeSize] unsignedLongLongValue] / 1048576;
			report(mb < 100 ? WADevWarn : WADevOK, [NSString stringWithFormat:@"%llu MB free", mb]);
		}),
		Test(@"App Memory", ^(WADevReport report) {
			struct task_basic_info info;
			mach_msg_type_number_t n = TASK_BASIC_INFO_COUNT;
			if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &n) != KERN_SUCCESS) return report(WADevWarn, @"no answer");
			unsigned long mb = (unsigned long)info.resident_size / 1048576;
			report(mb > 150 ? WADevWarn : WADevOK, [NSString stringWithFormat:@"%lu MB", mb]);
		}),
	];
}

#pragma mark - Page

@interface WADevTestsController : WATableController
@property (nonatomic) BOOL runNow;
@end

@implementation WADevTestsController {
	NSArray *_tests;
	BOOL _running;
	NSDate *_runStarted;
	NSTimeInterval _lastRun;
}

- (instancetype)init {
	if ((self = [super init])) {
		self.title = @"Self Tests";
		_tests = MakeTests();
	}
	return self;
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	if (self.runNow) {
		self.runNow = NO;
		[self runAll];
	}
}

- (void)rebuild {
	__weak WADevTestsController *weak = self;
	NSMutableArray *rows = [NSMutableArray array];
	for (WADevTest *test in _tests) {
		[rows addObject:@{@"title": test.name, @"subtitle": [self textFor:test], @"action": ^{ [weak runOne:test]; }}];
	}
	self.sections = @[
		@{@"rows": @[@{@"title": _running ? @"Running…" : @"Run All", @"button": @"blue", @"action": ^{ [weak runAll]; }}]},
		@{@"header": @"Tap one to run it again", @"footer": [self summary], @"rows": rows},
	];
}

- (NSString *)textFor:(WADevTest *)t {
	if (t.result == WADevWaiting) return t.attempt ? @"running…" : @"not run";
	return t.ms >= 20 ? [NSString stringWithFormat:@"%@, %d ms", t.detail, t.ms] : t.detail;
}

- (NSString *)summary {
	int counts[4] = {0, 0, 0, 0};
	for (WADevTest *t in _tests) counts[t.result]++;
	if (counts[WADevWaiting] == (int)_tests.count) return @"Not run yet.";
	return [NSString stringWithFormat:@"%d OK, %d warnings, %d failed. Took %.1f s.", counts[WADevOK], counts[WADevWarn], counts[WADevFail], _lastRun];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
	if (indexPath.section == 1) {
		WADevResult r = ((WADevTest *)_tests[indexPath.row]).result;
		cell.detailTextLabel.textColor = r == WADevOK ? WAColor(0x2E8B3D) : r == WADevWarn ? WAColor(0xC98A00) : r == WADevFail ? WAColor(0xC9302C) : WAColor(0x808080);
		cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
	}
	return cell;
}

- (void)runOne:(WADevTest *)test {
	if (_running) return;
	_running = YES;
	_runStarted = [NSDate date];
	[self run:@[test] index:0];
}

- (void)runAll {
	if (_running) return;
	_running = YES;
	_runStarted = [NSDate date];
	for (WADevTest *t in _tests) {
		t.result = WADevWaiting;
		t.attempt = 0;
		t.detail = nil;
	}
	[self run:_tests index:0];
}

- (void)run:(NSArray *)list index:(NSUInteger)i {
	if (i >= list.count) {
		_running = NO;
		_lastRun = -[_runStarted timeIntervalSinceNow];
		[self rebuild];
		[self save];
		return;
	}
	WADevTest *test = list[i];
	NSUInteger attempt = ++test.attempt;
	test.result = WADevWaiting;
	[self rebuild];
	NSDate *start = [NSDate date];
	__block BOOL reported = NO;
	WADevReport report = [^(WADevResult result, NSString *detail) {
		if (reported || test.attempt != attempt) return;
		reported = YES;
		test.result = result;
		test.detail = detail ?: @"";
		test.ms = (int)(-[start timeIntervalSinceNow] * 1000);
		[self run:list index:i + 1];
	} copy];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		report(WADevFail, @"no answer after 20 s");
	});
	test.run(report);
}

- (void)save {
	NSMutableString *out = [NSMutableString stringWithFormat:@"WA Dev self tests, internal version %@, %@\n", WADevVersion(), [NSDate date]];
	for (WADevTest *t in _tests) {
		NSString *mark = @[@"-", @"OK", @"WARN", @"FAIL"][t.result];
		[out appendFormat:@"%@ %@: %@ (%d ms)\n", mark, t.name, t.detail ?: @"not run", t.ms];
	}
	[out appendFormat:@"%@\n", [self summary]];
	[out writeToFile:[WADevFolder stringByAppendingPathComponent:@"dev-tests.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	WALog(@"dev: %@", [self summary]);
}

@end

UIViewController *WADevTestsPage(BOOL runNow) {
	WADevTestsController *page = [[WADevTestsController alloc] init];
	page.runNow = runNow;
	return page;
}

#pragma mark - Manual tests

// these show up on every iphone on the bridge, so never in Run All
@interface WADevManualController : WATableController
@end

@implementation WADevManualController {
	NSString *_messageResult, *_callResult, *_noteResult;
	NSString *_waitingFor;
	NSDate *_sent;
	id _observer;
}

- (instancetype)init {
	if ((self = [super init])) self.title = @"Manual Tests";
	return self;
}

- (void)dealloc {
	if (_observer) [[NSNotificationCenter defaultCenter] removeObserver:_observer];
}

- (void)rebuild {
	__weak WADevManualController *weak = self;
	self.sections = @[
		@{@"header": @"Test Message", @"footer": @"Fake message in the chat \"WA4S Test\", never reaches WhatsApp. Other iPhones on this bridge get it too.", @"rows": @[
			@{@"title": @"Incoming Message", @"subtitle": _messageResult ?: @"measures send to long poll", @"action": ^{ [weak sendMessage]; }},
			@{@"title": @"Remove Test Chat", @"action": ^{ [weak clearChat]; }},
		]},
		@{@"header": @"Test Call", @"footer": @"Rings on this bridge's iPhones. Answer = your own voice comes back.", @"rows": @[
			@{@"title": @"Incoming Call", @"subtitle": _callResult ?: @"ringing, call screen, echo", @"action": ^{ [weak ring]; }},
			@{@"title": @"End Test Call", @"action": ^{ [weak endCall]; }},
		]},
		@{@"header": @"Notification", @"footer": @"Only this iPhone. Press Home or lock it after tapping.", @"rows": @[
			@{@"title": @"Banner in 5 Seconds", @"subtitle": _noteResult ?: @"local notification with sound", @"action": ^{ [weak notifySoon]; }},
		]},
	];
}

- (void)sendMessage {
	NSString *text = [NSString stringWithFormat:@"Dev test %.0f", [NSDate timeIntervalSinceReferenceDate]];
	_waitingFor = text;
	_sent = [NSDate date];
	_messageResult = @"sending…";
	[self rebuild];
	if (!_observer) {
		__weak WADevManualController *weak = self;
		_observer = [[NSNotificationCenter defaultCenter] addObserverForName:WAClientUpdatesNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
			[weak updates:note];
		}];
	}
	[[WAClient shared] post:@"/api/debug/incoming" params:@{@"text": text} completion:^(id json, NSError *error) {
		if (error) {
			self->_waitingFor = nil;
			self->_messageResult = error.localizedDescription;
			[self rebuild];
		}
	}];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		if (![self->_waitingFor isEqualToString:text]) return;
		self->_waitingFor = nil;
		self->_messageResult = @"sent, but no long poll answer after 15 s";
		WALog(@"dev: test message didn't come back");
		[self rebuild];
	});
}

- (void)updates:(NSNotification *)note {
	if (!_waitingFor) return;
	for (NSDictionary *m in note.userInfo[@"messages"]) {
		if (![m[@"text"] isEqualToString:_waitingFor]) continue;
		int ms = (int)(-[_sent timeIntervalSinceNow] * 1000);
		_waitingFor = nil;
		_messageResult = [NSString stringWithFormat:@"came back after %d ms", ms];
		WALog(@"dev: test message came back after %d ms", ms);
		[self rebuild];
		return;
	}
}

- (void)clearChat {
	[[WAClient shared] post:@"/api/debug/clear" params:@{} completion:^(id json, NSError *error) {
		self->_messageResult = error ? error.localizedDescription : @"test chat removed";
		WALog(@"dev: %@", self->_messageResult);
		[self rebuild];
	}];
}

- (void)ring {
	[[WAClient shared] post:@"/api/debug/call" params:@{@"state": @"ringing", @"name": @"WA Dev Test"} completion:^(id json, NSError *error) {
		self->_callResult = error ? error.localizedDescription : @"ringing";
		WALog(@"dev: test call %@", self->_callResult);
		[self rebuild];
	}];
}

- (void)endCall {
	[[WAClient shared] post:@"/api/debug/call" params:@{@"state": @"ended"} completion:^(id json, NSError *error) {
		self->_callResult = error ? error.localizedDescription : @"ended";
		WALog(@"dev: test call %@", self->_callResult);
		[self rebuild];
	}];
}

- (void)notifySoon {
	UILocalNotification *note = [[UILocalNotification alloc] init];
	note.fireDate = [NSDate dateWithTimeIntervalSinceNow:5];
	note.alertBody = @"WA Dev test notification";
	note.soundName = @"Tri-tone.caf";
	[[UIApplication sharedApplication] scheduleLocalNotification:note];
	_noteResult = @"set, press Home now";
	[self rebuild];
}

@end

UIViewController *WADevManualPage(void) {
	return [[WADevManualController alloc] init];
}

void WADevManualPress(UIViewController *page, NSString *what) {
	WADevManualController *manual = (WADevManualController *)page;
	if ([what isEqualToString:@"message"]) [manual sendMessage];
	else if ([what isEqualToString:@"clear"]) [manual clearChat];
	else if ([what isEqualToString:@"ring"]) [manual ring];
	else if ([what isEqualToString:@"hangup"]) [manual endCall];
	else if ([what isEqualToString:@"banner"]) [manual notifySoon];
}

#pragma mark - Log

@interface WADevLogController : UIViewController
@end

@implementation WADevLogController {
	UITextView *_text;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Log";
	_text = [[UITextView alloc] initWithFrame:self.view.bounds];
	_text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_text.editable = NO;
	_text.font = [UIFont fontWithName:@"Courier" size:10];
	[self.view addSubview:_text];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
		target:self action:@selector(load)];
	[self load];
}

- (void)load {
	NSData *data = [NSData dataWithContentsOfFile:[WADevFolder stringByAppendingPathComponent:@"log.txt"]];
	NSUInteger keep = MIN(data.length, 12000);
	NSData *tail = [data subdataWithRange:NSMakeRange(data.length - keep, keep)];
	_text.text = [[NSString alloc] initWithData:tail encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:tail encoding:NSISOLatin1StringEncoding];
	dispatch_async(dispatch_get_main_queue(), ^{
		[self->_text scrollRangeToVisible:NSMakeRange(self->_text.text.length, 0)];
	});
}

@end

UIViewController *WADevLogPage(void) {
	return [[WADevLogController alloc] init];
}
