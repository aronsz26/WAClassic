#import "WAAssets.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <libkern/OSAtomic.h>
#import <notify.h>
#import "WACall.h"
#import "WAClient.h"
#import "WAPrefs.h"
#import "WAUtil.h"
#import "WAVideoCall.h"

NSString *const WACallChangedNotification = @"WACallChangedNotification";

#define kRate 16000
#define kRingSize 32768 // ~2s of ulaw

// simple SPSC ring buffer, audio thread <-> main thread
typedef struct {
	uint8_t data[kRingSize];
	volatile int64_t head, tail;
} WARing;

static int64_t RingCount(WARing *r) {
	OSMemoryBarrier();
	return r->head - r->tail;
}

static void RingPut(WARing *r, const uint8_t *bytes, int64_t n) {
	if (n > kRingSize - RingCount(r)) n = kRingSize - RingCount(r); // full, drop the rest
	for (int64_t i = 0; i < n; i++) r->data[(r->head + i) % kRingSize] = bytes[i];
	OSMemoryBarrier();
	r->head += n;
}

static int64_t RingGet(WARing *r, uint8_t *bytes, int64_t n) {
	int64_t have = RingCount(r);
	if (n > have) n = have;
	for (int64_t i = 0; i < n; i++) bytes[i] = r->data[(r->tail + i) % kRingSize];
	OSMemoryBarrier();
	r->tail += n;
	return n;
}

static void RingSkip(WARing *r, int64_t n) {
	OSMemoryBarrier();
	r->tail += n;
}

// ulaw, same as bridge
static uint8_t ULawEncode(int16_t s) {
	int v = s, sign = 0;
	if (v < 0) { v = -v; sign = 0x80; }
	if (v > 32635) v = 32635;
	v += 0x84;
	int exp = 7;
	for (int mask = 0x4000; !(v & mask) && exp > 0; mask >>= 1) exp--;
	int mant = (v >> (exp + 3)) & 0x0F;
	return (uint8_t)~(sign | (exp << 4) | mant);
}

static int16_t ULawTable[256];

static void ULawInit(void) {
	for (int i = 0; i < 256; i++) {
		uint8_t u = ~(uint8_t)i;
		int sign = u & 0x80, exp = (u >> 4) & 7, mant = u & 0x0F;
		int v = (((mant << 3) + 0x84) << exp) - 0x84;
		ULawTable[i] = (int16_t)(sign ? -v : v);
	}
}

// old C audio session api (ios 4/5) needs init once
static void WAInitCAudioSession(void) {
	static dispatch_once_t once;
	dispatch_once(&once, ^{ AudioSessionInitialize(NULL, NULL, NULL, NULL); });
}

@interface WACall () <NSStreamDelegate>
@property (nonatomic, copy) NSString *ownID;
@end

@implementation WACall {
	NSDictionary *_info;
	NSString *_shownID;
	NSString *_ownID; // call this phone answered/started, only this one gets audio
	NSDate *_answeredAt; // callback mode counts as ours too
	BOOL _starting; // waiting for the /api/call/start answer
	NSTimer *_poll, *_sendTimer, *_vibrate;
	BOOL _polling;
	AudioUnit _unit;
	BOOL _audioRunning;
	WARing _play, _rec;
	volatile BOOL _buffering, _ringback, _mutedFlag;
	// debug counters, logged every 5s
	volatile uint32_t _diagPlay, _diagLoud, _diagRecv, _diagRec;
	CFAbsoluteTime _diagLast;
	uint32_t _ringbackPhase;
	int16_t _recBuf[4096];
	AVAudioPlayer *_ringer;
	NSInputStream *_in;
	NSOutputStream *_out;
	NSMutableData *_head, *_pending;
	BOOL _headDone, _requestSent, _tls;
	NSDate *_activeSince;
	UILocalNotification *_ringNote;
	UIBackgroundTaskIdentifier _ringTask;
	SystemSoundID _ringSound;
	BOOL _sessionReady;
	NSString *_ringNoteID, *_missedID;
}

static NSString *const kCallScreenTweak = @"/Library/MobileSubstrate/DynamicLibraries/WACallScreen.dylib";

static void CallScreenChoice(CFNotificationCenterRef c, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
	NSString *what = [(__bridge NSString *)name pathExtension];
	dispatch_async(dispatch_get_main_queue(), ^{
		WALog(@"call screen: %@", what);
		WACall *call = [WACall shared];
		if ([what isEqualToString:@"answer"]) [call answer];
		else if ([what isEqualToString:@"mute"] || [what isEqualToString:@"unmute"]) call.muted = [what isEqualToString:@"mute"];
		else if ([what isEqualToString:@"speaker"] || [what isEqualToString:@"earpiece"]) call.speaker = [what isEqualToString:@"speaker"];
		else [call hangup];
		[call tellCallScreen];
	});
}

+ (WACall *)shared {
	static WACall *call;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		ULawInit();
		call = [[WACall alloc] init];
		[[NSNotificationCenter defaultCenter] addObserver:call selector:@selector(updatesArrived:)
			name:WAClientUpdatesNotification object:nil];
		// green bar brings you back during video
		[[NSNotificationCenter defaultCenter] addObserver:call selector:@selector(tellCallScreen)
			name:UIApplicationDidEnterBackgroundNotification object:nil];
		// lockscreen call ui (WACallScreen) talks to us via darwin notifs
		CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
		for (NSString *what in @[@"answer", @"decline", @"hangup", @"mute", @"unmute", @"speaker", @"earpiece"]) {
			CFNotificationCenterAddObserver(darwin, NULL, CallScreenChoice,
				(__bridge CFStringRef)[@"com.aronsz26.wa4s.callscreen." stringByAppendingString:what], NULL,
				CFNotificationSuspensionBehaviorDeliverImmediately);
		}
	});
	return call;
}

- (NSDictionary *)info { return _info; }
- (NSString *)state { return _info[@"state"]; }
- (NSDate *)activeSince { return _activeSince; }
// video hidden -> treat everything as voice
- (BOOL)video { return WAVideoCallsEnabled() && [_info[@"video"] boolValue]; }
- (BOOL)peerVideo { return WAVideoCallsEnabled() && [_info[@"peerVideo"] boolValue]; }
- (int)orientation { return [_info[@"orientation"] intValue]; }

// video bits can change without state changing
static BOOL SameMedia(NSDictionary *a, NSDictionary *b) {
	for (NSString *key in @[@"video", @"peerVideo", @"orientation"]) {
		if ([a[key] intValue] != [b[key] intValue]) return NO;
	}
	return YES;
}

- (BOOL)live {
	NSString *s = self.state;
	return s && ![s isEqualToString:@"ended"];
}

- (void)updatesArrived:(NSNotification *)note {
	NSDictionary *call = note.userInfo[@"call"];
	if ([call isKindOfClass:[NSDictionary class]]) [self updateWithInfo:call];
}

#pragma mark - State

- (void)updateWithInfo:(NSDictionary *)info {
	if (![info isKindOfClass:[NSDictionary class]] || ![info[@"id"] length]) return;
	NSString *old = _info[@"id"], *oldState = self.state;
	BOOL same = [old isEqualToString:info[@"id"]];
	// old ended call, ignore
	if (!same && [info[@"state"] isEqualToString:@"ended"]) {
		if (self.live || [info[@"id"] isEqualToString:_shownID]) return;
		_shownID = info[@"id"];
		_info = info;
		[self cancelRingNote];
		return;
	}
	if (same && [oldState isEqualToString:info[@"state"]]) {
		if (SameMedia(_info, info)) return;
		_info = info;
		[self tellCallScreen];
		[[WAVideoCall shared] update];
		[[NSNotificationCenter defaultCenter] postNotificationName:WACallChangedNotification object:self];
		return;
	}
	if (same && [oldState isEqualToString:@"ended"]) return;
	// another iphone on the same bridge took the call -> just stop ringing here
	NSString *st = info[@"state"];
	BOOL taken = [st isEqualToString:@"calling"] || [st isEqualToString:@"connecting"] || [st isEqualToString:@"active"];
	if (taken && [info[@"callback"] boolValue] && _answeredAt && -[_answeredAt timeIntervalSinceNow] < 15) self.ownID = info[@"id"];
	// long poll can beat the /api/call/start answer, that's still our call
	if (taken && _starting && ![info[@"incoming"] boolValue]) self.ownID = info[@"id"];
	if (taken && ![info[@"id"] isEqualToString:self.ownID]) {
		WALog(@"call: %@ on another iPhone", st);
		NSMutableDictionary *gone = [info mutableCopy];
		gone[@"state"] = @"ended";
		gone[@"reason"] = @"elsewhere";
		if (!same || [oldState isEqualToString:@"ended"]) {
			_info = gone;
			_shownID = info[@"id"];
			return;
		}
		info = gone;
	}
	_info = info;
	_shownID = info[@"id"];
	NSString *state = info[@"state"];
	WALog(@"call: %@", state);
	if ([state isEqualToString:@"active"] && !_activeSince) _activeSince = [NSDate date];
	if ([state isEqualToString:@"calling"] || [state isEqualToString:@"connecting"] || [state isEqualToString:@"active"]) {
		// stop ring first, otherwise no audio. when locked we restart audio after the ring instead
		BOOL answered = [oldState isEqualToString:@"ringing"];
		BOOL front = [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
		if (answered && front) [self stopRinging];
		_ringback = [state isEqualToString:@"calling"];
		if (!_audioRunning && (self.video || self.peerVideo)) _speaker = YES; // video = speaker
		[self startAudio];
		if (answered && !front) [self performSelector:@selector(restartAudioAfterRing) withObject:nil afterDelay:0.3];
	}
	if ([state isEqualToString:@"ringing"]) {
		[self startRinging];
	} else {
		[self stopRinging];
	}
	if ([state isEqualToString:@"ended"]) {
		[self stopAudio];
		[self cancelRingNote];
		if (oldState && ![oldState isEqualToString:@"ringing"]) [self playSystemSound:@"vc~ended"];
	}
	if (self.live) [self startPolling];
	else [self stopPolling];
	[[WAVideoCall shared] update];
	[self tellCallScreen];
	[[NSNotificationCenter defaultCenter] postNotificationName:WACallChangedNotification object:self];
}

+ (BOOL)systemCallScreen {
	return [[NSFileManager defaultManager] fileExistsAtPath:kCallScreenTweak];
}

// hand the call to the springboard tweak (callscreen.plist + avatar)
- (void)tellCallScreen {
	if (![WACall systemCallScreen]) return;
	NSString *dir = @"/var/mobile/Library/WA4S";
	NSMutableDictionary *call = [NSMutableDictionary dictionary];
	call[@"state"] = _info ? (self.state ?: @"none") : @"none";
	// video runs in the app, springboard only rings
	BOOL video = self.video || self.peerVideo;
	call[@"video"] = @(video);
	call[@"bundle"] = [NSBundle mainBundle].bundleIdentifier ?: @"";
	call[@"front"] = @([UIApplication sharedApplication].applicationState != UIApplicationStateBackground);
	if (video && self.live && ![self.state isEqualToString:@"ringing"]) call[@"state"] = @"video";
	call[@"muted"] = @(_muted);
	call[@"speaker"] = @(_speaker);
	call[@"callback"] = @([_info[@"callback"] boolValue]);
	call[@"id"] = _info[@"id"] ?: @"";
	call[@"name"] = [_info[@"name"] length] ? _info[@"name"] : @"WhatsApp";
	if (_activeSince) call[@"activeSince"] = @([_activeSince timeIntervalSince1970]);
	NSString *peer = _info[@"peer"];
	UIImage *pic = peer.length ? [[WAClient shared] cachedAvatarFor:peer] : nil;
	NSString *picPath = [dir stringByAppendingPathComponent:@"callscreen.jpg"];
	if (pic) [UIImageJPEGRepresentation(pic, 0.8) writeToFile:picPath atomically:YES];
	else [[NSFileManager defaultManager] removeItemAtPath:picPath error:NULL];
	[call writeToFile:[dir stringByAppendingPathComponent:@"callscreen.plist"] atomically:YES];
	notify_post("com.aronsz26.wa4s.callscreen.update");
}

- (void)refresh {
	if (![WAClient shared].configured) return;
	[[WAClient shared] get:@"/api/call/state" params:nil completion:^(id json, NSError *error) {
		if (!error) [self updateWithInfo:json];
	}];
}

// poll every sec during a call (long poll stops in bg)
- (void)startPolling {
	if (_poll) return;
	_poll = [NSTimer timerWithTimeInterval:1 target:self selector:@selector(pollTick) userInfo:nil repeats:YES];
	[[NSRunLoop mainRunLoop] addTimer:_poll forMode:NSRunLoopCommonModes];
}

- (void)stopPolling {
	[_poll invalidate];
	_poll = nil;
}

- (void)pollTick {
	if (_polling) return;
	_polling = YES;
	[[WAClient shared] get:@"/api/call/state" params:nil completion:^(id json, NSError *error) {
		self->_polling = NO;
		if (error) return;
		// call is gone (bridge restart?)
		NSString *mine = self->_info[@"id"];
		if (self.live && mine.length && ![json[@"id"] isEqualToString:mine]) {
			NSMutableDictionary *gone = [self->_info mutableCopy];
			gone[@"state"] = @"ended";
			gone[@"reason"] = @"lost";
			[self updateWithInfo:gone];
		}
		[self updateWithInfo:json];
	}];
}

- (void)callJID:(NSString *)jid name:(NSString *)name {
	[self callJID:jid name:name video:NO];
}

- (void)callJID:(NSString *)jid name:(NSString *)name video:(BOOL)video {
	if (self.live) return;
	_activeSince = nil;
	// show screen now, bridge answer replaces it
	_info = @{@"id": @"", @"peer": jid, @"name": name ?: @"", @"incoming": @NO, @"state": @"calling", @"video": @(video)};
	[[NSNotificationCenter defaultCenter] postNotificationName:WACallChangedNotification object:self];
	_starting = YES;
	[[WAClient shared] post:@"/api/call/start" params:@{@"chat": jid, @"video": video ? @"1" : @"0"} completion:^(id json, NSError *error) {
		self->_starting = NO;
		if (error) {
			WALog(@"call start: %@", error.localizedDescription);
			self->_info = @{@"id": @"", @"peer": jid, @"name": name ?: @"", @"incoming": @NO, @"state": @"ended",
				@"reason": error.localizedDescription ?: @"failed", @"video": @(video)};
			[[NSNotificationCenter defaultCenter] postNotificationName:WACallChangedNotification object:self];
			return;
		}
		if (!self.live) { // hung up while starting
			[[WAClient shared] post:@"/api/call/hangup" params:nil completion:^(id j, NSError *e) {}];
			return;
		}
		if ([json isKindOfClass:[NSDictionary class]] && [json[@"id"] length]) self.ownID = json[@"id"];
		[self updateWithInfo:json];
	}];
}

// save it, app might get relaunched mid call
- (NSString *)ownID {
	if (!_ownID) _ownID = [[NSUserDefaults standardUserDefaults] stringForKey:@"ownCallID"];
	return _ownID;
}

- (void)setOwnID:(NSString *)callID {
	_ownID = [callID copy];
	[[NSUserDefaults standardUserDefaults] setObject:callID forKey:@"ownCallID"];
}

- (void)answer {
	if (![self.state isEqualToString:@"ringing"]) return;
	self.ownID = _info[@"id"];
	_answeredAt = [NSDate date];
	// keep the ring playing silently, ios only lets us start call audio while sound is on
	_ringer.volume = 0;
	if (_ringSound) {
		SystemSoundID sound = _ringSound;
		_ringSound = 0;
		AudioServicesRemoveSystemSoundCompletion(sound);
		AudioServicesDisposeSystemSoundID(sound);
	}
	[_vibrate invalidate];
	_vibrate = nil;
	_activeSince = nil;
	[[WAClient shared] post:@"/api/call/answer" params:nil completion:^(id json, NSError *error) {
		if (error) WALog(@"answer: %@", error.localizedDescription);
		[self updateWithInfo:json];
		[self refresh];
	}];
}

- (void)hangup {
	_starting = NO;
	[self stopRinging];
	[[WAClient shared] post:@"/api/call/hangup" params:nil completion:^(id json, NSError *error) {
		[self updateWithInfo:json];
	}];
	if ([_info[@"id"] length] == 0) {
		NSMutableDictionary *info = [_info mutableCopy];
		info[@"state"] = @"ended";
		_info = info;
		[self stopAudio];
		[[NSNotificationCenter defaultCenter] postNotificationName:WACallChangedNotification object:self];
	}
}

- (void)setCameraOn:(BOOL)on {
	if (!self.live) return;
	[[WAClient shared] post:@"/api/call/camera" params:@{@"on": on ? @"1" : @"0"} completion:^(id json, NSError *error) {
		if (error) WALog(@"camera: %@", error.localizedDescription);
		else [self updateWithInfo:json];
	}];
}

- (void)setMuted:(BOOL)muted {
	_muted = muted;
	_mutedFlag = muted;
}

- (void)setSpeaker:(BOOL)speaker {
	_speaker = speaker;
	[self applyRoute];
}

- (void)applyRoute {
	if (!_audioRunning) return;
	AVAudioSession *session = [AVAudioSession sharedInstance];
	if ([session respondsToSelector:@selector(overrideOutputAudioPort:error:)]) {
		NSError *error = nil;
		[session overrideOutputAudioPort:_speaker ? AVAudioSessionPortOverrideSpeaker : AVAudioSessionPortOverrideNone error:&error];
		if (error) WALog(@"route: %@", error);
	} else { // ios 4/5
		WAInitCAudioSession();
		UInt32 route = _speaker ? kAudioSessionOverrideAudioRoute_Speaker : kAudioSessionOverrideAudioRoute_None;
		AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute, sizeof(route), &route);
	}
}

#pragma mark - Ringing

// ring/silent switch from springboard (1 = ring)
static BOOL RingerOn(void) {
	int token = 0;
	uint64_t state = 1;
	if (notify_register_check("com.apple.springboard.ringerstate", &token) == NOTIFY_STATUS_OK) {
		notify_get_state(token, &state);
		notify_cancel(token);
	}
	return state != 0;
}

// ringtone from settings, fallback springboard's
static NSURL *RingtoneURL(void) {
	NSDictionary *sb = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.apple.springboard.plist"];
	NSString *tone = sb[@"ringtone"];
	if ([tone hasPrefix:@"system:"]) {
		NSString *path = [NSString stringWithFormat:@"/Library/Ringtones/%@.m4r", [tone substringFromIndex:7]];
		if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return [NSURL fileURLWithPath:path];
	}
	return [NSURL fileURLWithPath:@"/System/Library/CoreServices/SpringBoard.app/ring.m4r"];
}

// Ringtone.caf (made by WAAssetsSync), 0 if missing
static SystemSoundID RingSound(void) {
	NSString *path = WABundleFile(@"Ringtone.caf");
	if (!path && [[NSFileManager defaultManager] fileExistsAtPath:WAAssetPath(@"Ringtone.caf")]) path = WAAssetPath(@"Ringtone.caf");
	SystemSoundID sound = 0;
	if (!path || AudioServicesCreateSystemSoundID((__bridge CFURLRef)[NSURL fileURLWithPath:path], &sound) != noErr) return 0;
	return sound;
}

// ring like a real call, also in bg/locked (audio bg mode keeps us alive)
- (void)startRinging {
	if (_ringer.playing || _vibrate) return;
	UIApplication *app = [UIApplication sharedApplication];
	if (_ringTask == UIBackgroundTaskInvalid || _ringTask == 0) {
		_ringTask = [app beginBackgroundTaskWithExpirationHandler:^{ [self stopRinging]; }];
	}
	// silent switch on: play at 0 volume, keeps app awake
	BOOL ring = RingerOn();
	// playback session while ringing, voicechat would mute the ring. mixable later when answered
	if (!_audioRunning) {
		AVAudioSession *session = [AVAudioSession sharedInstance];
		[session setCategory:AVAudioSessionCategoryPlayback error:NULL];
		[session setActive:YES error:NULL];
		_sessionReady = NO;
	}
	// play ring as alert sound (ringer volume, respects silent switch)
	_ringSound = RingSound();
	_ringer = [[AVAudioPlayer alloc] initWithContentsOfURL:RingtoneURL() error:NULL];
	_ringer.numberOfLoops = -1;
	_ringer.volume = _ringSound || !ring ? 0 : 1;
	[_ringer play];
	if (_ringSound) {
		AudioServicesAddSystemSoundCompletion(_ringSound, NULL, NULL, RingSoundFinished, (__bridge void *)self);
		AudioServicesPlayAlertSound(_ringSound);
	} else if (ring) { // loudspeaker, not earpiece
		WAInitCAudioSession();
		UInt32 route = kAudioSessionOverrideAudioRoute_Speaker;
		AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute, sizeof(route), &route);
	}
	WALog(@"call: ringing (%@)", ring ? (_ringSound ? @"ringer volume" : @"media volume") : @"vibrate only");
	AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
	_vibrate = [NSTimer timerWithTimeInterval:2.5 target:self selector:@selector(vibrate) userInfo:nil repeats:YES];
	[[NSRunLoop mainRunLoop] addTimer:_vibrate forMode:NSRunLoopCommonModes];
}

- (void)vibrate {
	AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
}

// next ring round
static void RingSoundFinished(SystemSoundID sound, void *ref) {
	WACall *self = (__bridge WACall *)ref;
	dispatch_async(dispatch_get_main_queue(), ^{
		if (self->_ringSound == sound) AudioServicesPlayAlertSound(sound);
	});
}

- (void)stopRinging {
	if (_ringSound) {
		SystemSoundID sound = _ringSound;
		_ringSound = 0;
		AudioServicesRemoveSystemSoundCompletion(sound);
		AudioServicesDisposeSystemSoundID(sound);
	}
	BOOL rang = _ringer != nil;
	[_ringer stop];
	_ringer = nil;
	[_vibrate invalidate];
	_vibrate = nil;
	if (rang && !_audioRunning) { // give audio back to other apps
		[[AVAudioSession sharedInstance] setActive:NO error:NULL];
		_sessionReady = NO;
	}
	if (_ringTask != UIBackgroundTaskInvalid && _ringTask != 0) {
		UIBackgroundTaskIdentifier task = _ringTask;
		_ringTask = UIBackgroundTaskInvalid;
		// wait a bit so missed call still shows
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
			[[UIApplication sharedApplication] endBackgroundTask:task];
		});
	}
}

- (void)playSystemSound:(NSString *)name {
	NSString *path = [NSString stringWithFormat:@"/System/Library/Audio/UISounds/%@.caf", name];
	SystemSoundID sound = 0;
	if (AudioServicesCreateSystemSoundID((__bridge CFURLRef)[NSURL fileURLWithPath:path], &sound) == noErr) {
		AudioServicesPlaySystemSound(sound);
	}
}

#pragma mark - Notifications (background)

- (void)notifyRinging:(NSDictionary *)info {
	NSString *state = info[@"state"];
	NSString *name = [info[@"name"] length] ? info[@"name"] : @"WhatsApp";
	UIApplication *app = [UIApplication sharedApplication];
	BOOL callScreen = [[NSFileManager defaultManager] fileExistsAtPath:kCallScreenTweak];
	if ([state isEqualToString:@"ringing"] && ![info[@"id"] isEqualToString:_ringNoteID] && callScreen) {
		_ringNoteID = info[@"id"]; // callscreen handles it
	} else if ([state isEqualToString:@"ringing"] && ![info[@"id"] isEqualToString:_ringNoteID]) {
		_ringNoteID = info[@"id"];
		[self cancelRingNote];
		UILocalNotification *n = [[UILocalNotification alloc] init];
		n.alertBody = [NSString stringWithFormat:WAVideoCallsEnabled() && [info[@"video"] boolValue] ? @"%@: Incoming video call" : @"%@: Incoming voice call", name];
		n.alertAction = @"answer";
		// silent notif, we ring ourselves
		n.userInfo = @{@"call": info[@"id"] ?: @"", @"chat": info[@"peer"] ?: @""};
		[app presentLocalNotificationNow:n];
		_ringNote = n;
		WALog(@"call notification shown");
	} else if ([state isEqualToString:@"ended"] && ![info[@"id"] isEqualToString:_missedID]) {
		_missedID = info[@"id"];
		// missed while asleep
		[self cancelRingNote];
		UILocalNotification *n = [[UILocalNotification alloc] init];
		n.alertBody = [NSString stringWithFormat:WAVideoCallsEnabled() && [info[@"video"] boolValue] ? @"%@: Missed video call" : @"%@: Missed voice call", name];
		n.alertAction = @"View";
		n.soundName = [self bundleSound:@"Tri-tone.caf"];
		n.userInfo = @{@"chat": info[@"peer"] ?: @""};
		[app presentLocalNotificationNow:n];
		WALog(@"missed call notification shown");
	}
	[self updateWithInfo:info];
}

- (NSString *)bundleSound:(NSString *)file {
	return WABundleFile(file) ? file : UILocalNotificationDefaultSoundName;
}

- (void)cancelRingNote {
	if (!_ringNote) return;
	[[UIApplication sharedApplication] cancelLocalNotification:_ringNote];
	_ringNote = nil;
}

#pragma mark - Audio unit

static OSStatus RecordCallback(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
		UInt32 bus, UInt32 frames, AudioBufferList *unused) {
	WACall *self = (__bridge WACall *)ref;
	if (frames > 4096) return noErr;
	AudioBufferList list;
	list.mNumberBuffers = 1;
	list.mBuffers[0].mNumberChannels = 1;
	list.mBuffers[0].mDataByteSize = frames * 2;
	list.mBuffers[0].mData = self->_recBuf;
	OSStatus err = AudioUnitRender(self->_unit, flags, ts, 1, frames, &list);
	if (err) return err;
	uint8_t out[4096];
	BOOL mute = self->_mutedFlag;
	for (UInt32 i = 0; i < frames; i++) out[i] = mute ? 0xFF : ULawEncode(self->_recBuf[i]);
	RingPut(&self->_rec, out, frames);
	self->_diagRec++;
	return noErr;
}

static OSStatus PlayCallback(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
		UInt32 bus, UInt32 frames, AudioBufferList *data) {
	WACall *self = (__bridge WACall *)ref;
	int16_t *samples = data->mBuffers[0].mData;
	UInt32 n = MIN(frames, data->mBuffers[0].mDataByteSize / 2);
	if (self->_ringback) {
		// ringback tone 425hz 1s on 4s off
		for (UInt32 i = 0; i < n; i++, self->_ringbackPhase++) {
			uint32_t t = self->_ringbackPhase % (5 * kRate);
			samples[i] = t < kRate ? (int16_t)(sinf(2 * (float)M_PI * 425 * t / kRate) * 6000) : 0;
		}
		RingSkip(&self->_play, RingCount(&self->_play));
		return noErr;
	}
	int64_t have = RingCount(&self->_play);
	// jitter buffer 120-400ms
	if (self->_buffering && have >= kRate * 12 / 100) self->_buffering = NO;
	if (have > kRate * 4 / 10) RingSkip(&self->_play, have - kRate * 15 / 100);
	uint8_t in[4096];
	int64_t got = self->_buffering ? 0 : RingGet(&self->_play, in, MIN(n, 4096));
	int16_t loudest = 0;
	for (UInt32 i = 0; i < n; i++) {
		samples[i] = i < got ? ULawTable[in[i]] : 0;
		if (samples[i] > loudest) loudest = samples[i];
	}
	if (got < n) self->_buffering = YES;
	self->_diagPlay++;
	if (loudest > 300) self->_diagLoud++;
	return noErr;
}

// voicechat session 16khz. set up already while ringing, ios won't let bg apps change it later ('!cat')
- (void)prepareCallSession {
	if (_sessionReady) return;
	AVAudioSession *session = [AVAudioSession sharedInstance];
	NSError *error = nil;
	// mixable so it works from bg
	BOOL background = [UIApplication sharedApplication].applicationState == UIApplicationStateBackground;
	if (background && [session respondsToSelector:@selector(setCategory:withOptions:error:)]) {
		[session setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&error];
	} else {
		[session setCategory:AVAudioSessionCategoryPlayAndRecord error:&error];
	}
	if ([session respondsToSelector:@selector(setMode:error:)]) [session setMode:AVAudioSessionModeVoiceChat error:NULL];
	if ([session respondsToSelector:@selector(setPreferredSampleRate:error:)]) {
		[session setPreferredSampleRate:kRate error:NULL];
	} else {
		WAInitCAudioSession();
		Float64 rate = kRate;
		AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareSampleRate, sizeof(rate), &rate);
		UInt32 mix = background;
		AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof(mix), &mix);
	}
	[session setPreferredIOBufferDuration:0.02 error:NULL];
	[session setActive:YES error:&error];
	if (error) WALog(@"audio session (%@): %@", background ? @"background" : @"front", error);
	_sessionReady = !error;
}

- (void)startAudio {
	if (_audioRunning) return;
	AVAudioSession *session = [AVAudioSession sharedInstance];
	[self prepareCallSession];
	// back to earpiece after ring
	WAInitCAudioSession();
	UInt32 route = kAudioSessionOverrideAudioRoute_None;
	AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute, sizeof(route), &route);

	AudioComponentDescription desc = {kAudioUnitType_Output, kAudioUnitSubType_VoiceProcessingIO, kAudioUnitManufacturer_Apple, 0, 0};
	AudioComponent comp = AudioComponentFindNext(NULL, &desc);
	if (!comp || AudioComponentInstanceNew(comp, &_unit)) {
		WALog(@"no voice processing unit");
		return;
	}
	UInt32 one = 1;
	AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, sizeof(one));
	AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, sizeof(one));
	AudioStreamBasicDescription fmt = {0};
	fmt.mSampleRate = kRate;
	fmt.mFormatID = kAudioFormatLinearPCM;
	fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
	fmt.mChannelsPerFrame = 1;
	fmt.mBitsPerChannel = 16;
	fmt.mBytesPerFrame = 2;
	fmt.mFramesPerPacket = 1;
	fmt.mBytesPerPacket = 2;
	AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, sizeof(fmt));
	AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));
	AURenderCallbackStruct rec = {RecordCallback, (__bridge void *)self};
	AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &rec, sizeof(rec));
	AURenderCallbackStruct play = {PlayCallback, (__bridge void *)self};
	AudioUnitSetProperty(_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &play, sizeof(play));
	_play.head = _play.tail = _rec.head = _rec.tail = 0;
	_buffering = YES;
	_ringbackPhase = 0;
	OSStatus err = AudioUnitInitialize(_unit);
	if (!err) err = AudioOutputUnitStart(_unit);
	if (err) {
		WALog(@"audio unit start failed: %d", (int)err);
		AudioComponentInstanceDispose(_unit);
		_unit = NULL;
		return;
	}
	_audioRunning = YES;
	WALog(@"audio started (%.0f Hz)", [session respondsToSelector:@selector(sampleRate)] ? session.sampleRate
		: session.currentHardwareSampleRate);
	[self applyRoute];
	[self connectAudio];
	_sendTimer = [NSTimer timerWithTimeInterval:0.02 target:self selector:@selector(sendTick) userInfo:nil repeats:YES];
	[[NSRunLoop mainRunLoop] addTimer:_sendTimer forMode:NSRunLoopCommonModes];
}

// answered in bg: restart audio unit after ring, else no output
- (void)restartAudioAfterRing {
	if (!_audioRunning || !_unit || !self.live) return;
	[self stopRinging];
	AudioOutputUnitStop(_unit);
	OSStatus err = AudioOutputUnitStart(_unit);
	[self applyRoute];
	WALog(@"audio restarted after the ring (%d)", (int)err);
}

- (void)stopAudio {
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(restartAudioAfterRing) object:nil];
	[_sendTimer invalidate];
	_sendTimer = nil;
	[self closeSocket];
	if (_unit) {
		AudioOutputUnitStop(_unit);
		AudioUnitUninitialize(_unit);
		AudioComponentInstanceDispose(_unit);
		_unit = NULL;
	}
	if (_audioRunning) {
		_audioRunning = NO;
		[[AVAudioSession sharedInstance] setActive:NO error:NULL];
		_sessionReady = NO;
		WALog(@"audio stopped");
	}
	_ringback = NO;
	_muted = _mutedFlag = NO;
	_speaker = NO;
}

#pragma mark - Audio socket

- (void)connectAudio {
	[self closeSocket];
	WAClient *client = [WAClient shared];
	NSURL *url = [NSURL URLWithString:client.serverURL];
	if (!url.host) return;
	_tls = [url.scheme isEqualToString:@"https"];
	int port = url.port ? url.port.intValue : (_tls ? 443 : 80);
	CFReadStreamRef readStream = NULL;
	CFWriteStreamRef writeStream = NULL;
	CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)url.host, port, &readStream, &writeStream);
	if (!readStream || !writeStream) return;
	if (_tls) {
		NSDictionary *ssl = @{(__bridge id)kCFStreamSSLValidatesCertificateChain: @NO,
			(__bridge id)kCFStreamSSLLevel: (__bridge id)kCFStreamSocketSecurityLevelNegotiatedSSL};
		CFReadStreamSetProperty(readStream, kCFStreamPropertySSLSettings, (__bridge CFDictionaryRef)ssl);
		CFWriteStreamSetProperty(writeStream, kCFStreamPropertySSLSettings, (__bridge CFDictionaryRef)ssl);
	}
	_in = CFBridgingRelease(readStream);
	_out = CFBridgingRelease(writeStream);
	_head = [NSMutableData data];
	_pending = [NSMutableData data];
	_headDone = _requestSent = NO;
	NSString *req = [NSString stringWithFormat:@"GET /api/call/audio HTTP/1.0\r\nHost: %@:%d\r\nX-WA4S-Token: %@\r\n\r\n",
		url.host, port, client.token];
	[_pending appendData:[req dataUsingEncoding:NSUTF8StringEncoding]];
	for (NSStream *s in @[_in, _out]) {
		s.delegate = self;
		[s scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
		[s open];
	}
}

- (void)closeSocket {
	for (NSStream *s in @[_in ?: (id)[NSNull null], _out ?: (id)[NSNull null]]) {
		if ([s isKindOfClass:[NSNull class]]) continue;
		s.delegate = nil;
		[s close];
		[s removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
	}
	_in = nil;
	_out = nil;
}

- (void)reconnectSoon {
	[self closeSocket];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		if (self->_audioRunning && !self->_in) [self connectAudio];
	});
}

// mic -> bridge every 20ms
// audio diag every 5s
- (void)logAudioDiagnostics {
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (now - _diagLast < 5) return;
	_diagLast = now;
	WAInitCAudioSession();
	CFStringRef route = NULL;
	UInt32 size = sizeof(route);
	AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &size, &route);
	Float32 volume = -1;
	size = sizeof(volume);
	AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareOutputVolume, &size, &volume);
	WALog(@"audio diag: %u renders (%u with sound), %u bytes in, %u mic, route %@, volume %.2f, state %d",
		_diagPlay, _diagLoud, _diagRecv, _diagRec, route ? (__bridge NSString *)route : @"?", volume,
		(int)[UIApplication sharedApplication].applicationState);
	if (route) CFRelease(route);
	_diagPlay = _diagLoud = _diagRecv = _diagRec = 0;
}

- (void)sendTick {
	[self logAudioDiagnostics];
	if (!_out) return;
	if (_headDone) {
		uint8_t buf[4096];
		int64_t n;
		while ((n = RingGet(&_rec, buf, sizeof(buf))) > 0) [_pending appendBytes:buf length:(NSUInteger)n];
		// bridge keeps max 300ms anyway
		if (_pending.length > 8000) [_pending replaceBytesInRange:NSMakeRange(0, _pending.length - 4800) withBytes:NULL length:0];
	} else if (_requestSent) {
		RingSkip(&_rec, RingCount(&_rec));
	}
	[self flush];
}

- (void)flush {
	if (!_pending.length || !_out.hasSpaceAvailable) return;
	if (!_requestSent && _tls) {
		SecTrustRef trust = (__bridge SecTrustRef)[_out propertyForKey:(__bridge NSString *)kCFStreamPropertySSLPeerTrust];
		if (!WAPinMatches(trust, [WAClient shared].pin)) {
			WALog(@"call audio: certificate does not match the pin");
			[self closeSocket];
			return;
		}
	}
	NSInteger written = [_out write:_pending.bytes maxLength:_pending.length];
	if (written > 0) {
		[_pending replaceBytesInRange:NSMakeRange(0, written) withBytes:NULL length:0];
		_requestSent = YES;
	}
}

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)event {
	switch (event) {
		case NSStreamEventHasSpaceAvailable:
			[self flush];
			break;
		case NSStreamEventHasBytesAvailable: {
			uint8_t buf[4096];
			NSInteger n;
			while (_in.hasBytesAvailable && (n = [_in read:buf maxLength:sizeof(buf)]) > 0) {
				if (_headDone) {
					RingPut(&_play, buf, n);
					_diagRecv += (uint32_t)n;
					continue;
				}
				[_head appendBytes:buf length:n];
				NSRange r = [_head rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4] options:0 range:NSMakeRange(0, _head.length)];
				if (r.location == NSNotFound) continue;
				NSString *line = [[NSString alloc] initWithData:[_head subdataWithRange:NSMakeRange(0, MIN(r.location, (NSUInteger)20))]
					encoding:NSUTF8StringEncoding];
				if (![line hasPrefix:@"HTTP/1.1 200"] && ![line hasPrefix:@"HTTP/1.0 200"]) {
					WALog(@"call audio refused: %@", line);
					[self reconnectSoon];
					return;
				}
				_headDone = YES;
				WALog(@"call audio connected");
				NSUInteger rest = NSMaxRange(r);
				if (_head.length > rest) RingPut(&_play, (const uint8_t *)_head.bytes + rest, _head.length - rest);
			}
			break;
		}
		case NSStreamEventEndEncountered:
		case NSStreamEventErrorOccurred:
			WALog(@"call audio closed: %@", stream.streamError);
			// reconnect unless call ended
			[self refresh];
			[self reconnectSoon];
			break;
		default:
			break;
	}
}

@end
