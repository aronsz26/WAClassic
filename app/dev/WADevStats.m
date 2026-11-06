#import <mach/mach.h>
#import <sys/sysctl.h>
#import <netinet/in.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import "WADev.h"
#import "../WAClient.h"
#import "../WACall.h"
#import "../WAPrefs.h"
#import "../WASettingsPages.h"
#import "../WAUtil.h"

// live numbers, one second refresh, ping every 3 s

static NSString *ByteText(unsigned long long n) {
	if (n >= 1048576) return [NSString stringWithFormat:@"%.1f MB", n / 1048576.0];
	if (n >= 1024) return [NSString stringWithFormat:@"%.0f KB", n / 1024.0];
	return [NSString stringWithFormat:@"%llu B", n];
}

static NSString *Span(NSTimeInterval s) {
	long t = (long)s;
	if (t < 60) return [NSString stringWithFormat:@"%ld s", t];
	if (t < 3600) return [NSString stringWithFormat:@"%ld min %ld s", t / 60, t % 60];
	return [NSString stringWithFormat:@"%ld h %ld min", t / 3600, t / 60 % 60];
}

static NSString *Sysctl(const char *name) {
	char buf[64] = {0};
	size_t len = sizeof(buf) - 1;
	return sysctlbyname(name, buf, &len, NULL, 0) == 0 ? @(buf) : @"?";
}

static unsigned long long AppMemory(void) {
	struct task_basic_info info;
	mach_msg_type_number_t n = TASK_BASIC_INFO_COUNT;
	return task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &n) == KERN_SUCCESS ? info.resident_size : 0;
}

static unsigned long long FreeMemory(void) {
	vm_statistics_data_t vm;
	mach_msg_type_number_t n = HOST_VM_INFO_COUNT;
	vm_size_t page = 4096;
	host_page_size(mach_host_self(), &page);
	return host_statistics(mach_host_self(), HOST_VM_INFO, (host_info_t)&vm, &n) == KERN_SUCCESS ? (unsigned long long)vm.free_count * page : 0;
}

static NSString *NetworkKind(void) {
	struct sockaddr_in zero = {0};
	zero.sin_len = sizeof(zero);
	zero.sin_family = AF_INET;
	SCNetworkReachabilityRef r = SCNetworkReachabilityCreateWithAddress(NULL, (const struct sockaddr *)&zero);
	SCNetworkReachabilityFlags flags = 0;
	BOOL ok = r && SCNetworkReachabilityGetFlags(r, &flags);
	if (r) CFRelease(r);
	if (!ok || !(flags & kSCNetworkReachabilityFlagsReachable)) return @"none";
	return flags & kSCNetworkReachabilityFlagsIsWWAN ? @"cellular" : @"Wi-Fi";
}

// folder size once per page, not each second
static void FolderInfo(NSString *path, NSUInteger *files, unsigned long long *bytes) {
	NSFileManager *fm = [NSFileManager defaultManager];
	for (NSString *name in [fm enumeratorAtPath:path]) {
		NSDictionary *a = [fm attributesOfItemAtPath:[path stringByAppendingPathComponent:name] error:NULL];
		if (![a.fileType isEqualToString:NSFileTypeRegular]) continue;
		(*files)++;
		*bytes += a.fileSize;
	}
}

// pings survive leaving the page
static int lastPing = -1, maxPing, pings, lostPings;
static double pingSum;
static NSDictionary *lastStatus;
static NSMutableArray *currentSections;

static NSArray *MakeSections(NSUInteger assetFiles, unsigned long long assetBytes) {
	NSFileManager *fm = [NSFileManager defaultManager];
	WAClient *c = [WAClient shared];
	WADevCounters n = WADevCount;
	NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
	NSDictionary *fs = [fm attributesOfFileSystemForPath:@"/var/mobile" error:NULL];
	unsigned long long logSize = [fm attributesOfItemAtPath:[WADevFolder stringByAppendingPathComponent:@"log.txt"] error:NULL].fileSize;
	NSURL *server = [NSURL URLWithString:c.serverURL ?: @""];
	NSString *whatsapp = !lastStatus ? @"bridge not reached" : [lastStatus[@"connected"] boolValue] ? @"connected" : [lastStatus[@"paired"] boolValue] ? @"disconnected" : @"not linked";
	WACall *call = [WACall shared];
	NSDictionary *(^row)(NSString *, NSString *) = ^(NSString *title, NSString *detail) {
		return @{@"title": title, @"detail": detail ?: @"–"};
	};
	return @[
		@{@"header": @"App", @"rows": @[
			row(@"Internal Version", WADevVersion()),
			row(@"Commit", @WA_DEV_COMMIT),
			row(@"Built", @WA_DEV_DATE),
			row(@"Running For", Span(now - n.started)),
			row(@"iOS", [NSString stringWithFormat:@"%@ (%@)", [UIDevice currentDevice].systemVersion, Sysctl("kern.osversion")]),
			row(@"Device", Sysctl("hw.machine")),
		]},
		@{@"header": @"Memory and Disk", @"rows": @[
			row(@"App Memory", ByteText(AppMemory())),
			row(@"Free Memory", ByteText(FreeMemory())),
			row(@"Free Disk", ByteText([fs[NSFileSystemFreeSize] unsignedLongLongValue])),
			row(@"Look Files", [NSString stringWithFormat:@"%lu, %@", (unsigned long)assetFiles, ByteText(assetBytes)]),
			row(@"Log File", ByteText(logSize)),
		]},
		@{@"header": @"Bridge", @"rows": @[
			row(@"WhatsApp", whatsapp),
			row(@"Bridge Version", lastStatus[@"version"]),
			row(@"Using", [NSString stringWithFormat:@"%@, %@", c.away ? @"away" : @"home", server.scheme ?: @"?"]),
			row(@"Host", server.host ? [NSString stringWithFormat:@"%@:%@", server.host, server.port ?: @"-"] : nil),
			row(@"Network", NetworkKind()),
			row(@"Latency", lastPing < 0 ? nil : [NSString stringWithFormat:@"%d ms", lastPing]),
			row(@"Average", pings ? [NSString stringWithFormat:@"%.0f ms (%d pings)", pingSum / pings, pings] : nil),
			row(@"Slowest", pings ? [NSString stringWithFormat:@"%d ms", maxPing] : nil),
			row(@"Lost Pings", [NSString stringWithFormat:@"%d", lostPings]),
			row(@"Update Counter", [NSString stringWithFormat:@"%lld", c.upd]),
		]},
		@{@"header": @"Traffic Since Start", @"rows": @[
			row(@"Requests", [NSString stringWithFormat:@"%llu", n.requests]),
			row(@"Failed", [NSString stringWithFormat:@"%llu", n.failed]),
			row(@"Received", ByteText(n.bytesIn)),
			row(@"Sent", ByteText(n.bytesOut)),
			row(@"Long Poll Events", [NSString stringWithFormat:@"%llu", n.polls]),
			row(@"Messages Seen", [NSString stringWithFormat:@"%llu", n.messages]),
			row(@"Last Event", n.lastUpdate ? [Span(now - n.lastUpdate) stringByAppendingString:@" ago"] : nil),
			row(@"Address Switches", [NSString stringWithFormat:@"%llu", n.serverSwitches]),
			row(@"Network Changes", [NSString stringWithFormat:@"%llu", n.networkChanges]),
		]},
		@{@"header": @"Calls", @"rows": @[
			row(@"State", call.state ?: @"no call"),
			row(@"Call Screen Tweak", [WACall systemCallScreen] ? @"installed" : @"missing"),
			row(@"Video Calls", WAVideoCallsEnabled() ? @"on" : @"off"),
		]},
	];
}

@interface WADevStatsController : WATableController
@end

@implementation WADevStatsController {
	NSTimer *_timer;
	NSUInteger _ticks, _assetFiles;
	unsigned long long _assetBytes;
	BOOL _pinging;
}

- (instancetype)init {
	if ((self = [super init])) {
		self.title = @"Stats";
		FolderInfo([WADevFolder stringByAppendingPathComponent:@"Assets"], &_assetFiles, &_assetBytes);
	}
	return self;
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	[self ping];
	_timer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[_timer invalidate];
	_timer = nil;
}

- (void)tick {
	if (++_ticks % 3 == 0) [self ping];
	[self rebuild];
}

- (void)ping {
	if (_pinging) return;
	_pinging = YES;
	NSDate *start = [NSDate date];
	[[WAClient shared] get:@"/api/status" params:nil completion:^(id json, NSError *error) {
		self->_pinging = NO;
		if (error || ![json isKindOfClass:[NSDictionary class]]) {
			lostPings++;
			lastStatus = nil;
		} else {
			lastPing = (int)(-[start timeIntervalSinceNow] * 1000);
			maxPing = MAX(maxPing, lastPing);
			pingSum += lastPing;
			pings++;
			lastStatus = json;
		}
		[self rebuild];
	}];
}

- (void)rebuild {
	NSArray *sections = MakeSections(_assetFiles, _assetBytes);
	currentSections = [sections mutableCopy];
	self.sections = sections;
}

@end

UIViewController *WADevStatsPage(void) {
	return [[WADevStatsController alloc] init];
}

void WADevDumpStats(void) {
	NSMutableString *out = [NSMutableString stringWithFormat:@"WA Dev stats, %@\n", [NSDate date]];
	for (NSDictionary *section in currentSections) {
		[out appendFormat:@"\n[%@]\n", section[@"header"]];
		for (NSDictionary *row in section[@"rows"]) [out appendFormat:@"%@: %@\n", row[@"title"], row[@"detail"]];
	}
	[out writeToFile:[WADevFolder stringByAppendingPathComponent:@"dev-stats.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
