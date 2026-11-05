// WACallScreen - shows WA calls in springboard's real call screen
// app writes callscreen.plist (+ .jpg) and posts com.aronsz26.wa4s.callscreen.update,
// audio stays in the app. ui uses TelephonyUI / MobilePhone pieces:
// locked:   LCD bar + slide to answer
// unlocked: decline / answer (own buttons on ios 4)
// in call:  name, timer, 6 buttons, end
// home -> green "touch to return" bar, tap it to come back.
// buttons are sent back as com.aronsz26.wa4s.callscreen.<action>
// no ARC, one build for ios 4-6

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <notify.h>

#define kDir @"/var/mobile/Library/WA4S"
#define kTelephonyUI @"/System/Library/PrivateFrameworks/TelephonyUI.framework"
#define kPhoneApp @"/Applications/MobilePhone.app"

// log to callscreen-log.txt (no syslog on ios 4), keep it small
static void CSLog(NSString *format, ...) {
	va_list args;
	va_start(args, format);
	NSString *line = [[[NSString alloc] initWithFormat:format arguments:args] autorelease];
	va_end(args);
	NSString *path = [kDir stringByAppendingPathComponent:@"callscreen-log.txt"];
	NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
	if ([attrs fileSize] > 100000) [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
	NSFileHandle *f = [NSFileHandle fileHandleForWritingAtPath:path];
	if (!f) {
		[[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
		f = [NSFileHandle fileHandleForWritingAtPath:path];
	}
	[f seekToEndOfFile];
	[f writeData:[[NSString stringWithFormat:@"%@ %@\n", [NSDate date], line] dataUsingEncoding:NSUTF8StringEncoding]];
	[f closeFile];
}

static id Send(id target, const char *name) {
	SEL sel = sel_registerName(name);
	return [target respondsToSelector:sel] ? ((id (*)(id, SEL))objc_msgSend)(target, sel) : nil;
}

static BOOL SendBool(id target, const char *name) {
	SEL sel = sel_registerName(name);
	return [target respondsToSelector:sel] ? ((BOOL (*)(id, SEL))objc_msgSend)(target, sel) : NO;
}

static void SendObject(id target, const char *name, id arg) {
	SEL sel = sel_registerName(name);
	if ([target respondsToSelector:sel]) ((void (*)(id, SEL, id))objc_msgSend)(target, sel, arg);
}

// struct/float returns go through the IMP, plain objc_msgSend crashed springboard (stret on armv7)
static CGSize ClassSize(Class c, const char *name) {
	Method m = c ? class_getClassMethod(c, sel_registerName(name)) : NULL;
	return m ? ((CGSize (*)(id, SEL))method_getImplementation(m))(c, sel_registerName(name)) : CGSizeZero;
}

static CGFloat ClassFloat(Class c, const char *name, CGFloat fallback) {
	Method m = c ? class_getClassMethod(c, sel_registerName(name)) : NULL;
	return m ? ((CGFloat (*)(id, SEL))method_getImplementation(m))(c, sel_registerName(name)) : fallback;
}

static id AwayController(void) {
	return Send(objc_getClass("SBAwayController"), "sharedAwayController");
}

static BOOL DeviceLocked(void) {
	return SendBool(AwayController(), "isLocked");
}

static NSString *Str(NSDictionary *d, NSString *key) {
	id v = [d objectForKey:key];
	return [v isKindOfClass:[NSString class]] ? v : nil;
}

// whatever variant the device has
static UIImage *SystemImage(NSString *dir, NSString *name) {
	CGFloat scale = [UIScreen mainScreen].scale;
	NSArray *suffixes = scale > 1 ? [NSArray arrayWithObjects:@"@2x~iphone", @"@2x", @"~iphone", @"", nil]
		: [NSArray arrayWithObjects:@"~iphone", @"", @"@2x~iphone", @"@2x", nil];
	for (NSString *s in suffixes) {
		UIImage *img = [UIImage imageWithContentsOfFile:[NSString stringWithFormat:@"%@/%@%@.png", dir, name, s]];
		if (img) return [s hasPrefix:@"@2x"] ? [UIImage imageWithCGImage:img.CGImage scale:2 orientation:UIImageOrientationUp] : img;
	}
	return nil;
}

// ios 5+
static UIImage *Stretch(UIImage *img, UIEdgeInsets caps) {
	if ([img respondsToSelector:@selector(resizableImageWithCapInsets:)]) return [img resizableImageWithCapInsets:caps];
	return [img stretchableImageWithLeftCapWidth:(NSInteger)caps.left topCapHeight:0];
}

// lock wallpaper: jpeg on old ios, cpbitmap on newer
static UIImage *LockWallpaper(void) {
	NSString *dir = @"/var/mobile/Library/SpringBoard";
	UIImage *jpg = [UIImage imageWithContentsOfFile:[dir stringByAppendingPathComponent:@"LockBackground.jpg"]];
	if (jpg) return jpg;
	void *as = dlopen("/System/Library/PrivateFrameworks/AppSupport.framework/AppSupport", RTLD_LAZY);
	CFArrayRef (*create)(CFStringRef, CFPropertyListRef *, uint32_t, CFErrorRef *) = as ? dlsym(as, "CPBitmapCreateImagesFromPath") : NULL;
	if (!create) return nil;
	CFArrayRef images = create((CFStringRef)[dir stringByAppendingPathComponent:@"LockBackground.cpbitmap"], NULL, 0, NULL);
	UIImage *img = nil;
	if (images && CFArrayGetCount(images)) {
		img = [UIImage imageWithCGImage:(CGImageRef)CFArrayGetValueAtIndex(images, 0) scale:[UIScreen mainScreen].scale
			orientation:UIImageOrientationUp];
	}
	if (images) CFRelease(images);
	return img;
}

// dark bg when there's no avatar
static UIImage *CallBackground(CGFloat height) {
	UIGraphicsBeginImageContextWithOptions(CGSizeMake(1, height), YES, 1);
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
	CGFloat comps[8] = {0.20, 0.23, 0.28, 1, 0.04, 0.05, 0.06, 1};
	CGGradientRef g = CGGradientCreateWithColorComponents(space, comps, NULL, 2);
	CGContextDrawLinearGradient(ctx, g, CGPointZero, CGPointMake(0, height), 0);
	CGGradientRelease(g);
	CGColorSpaceRelease(space);
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

static UIView *FindView(UIView *v, Class c) {
	if (!v || !c) return nil;
	if ([v isKindOfClass:c]) return v;
	for (UIView *sub in v.subviews) {
		UIView *hit = FindView(sub, c);
		if (hit) return hit;
	}
	return nil;
}

// date view sits in a container of the lock LCD that ends up at alpha 0 after a call
static void ShowLockClock(void) {
	UIView *date = FindView(Send(AwayController(), "awayView"), objc_getClass("SBAwayDateView"));
	UIView *box = date.superview;
	if (!box || box.alpha > 0) return;
	box.alpha = 1;
	CSLog(@"lock clock was hidden, shown again");
}

@interface WACallScreen : NSObject
- (BOOL)homePressed;
- (BOOL)returnToCall;
@end

@implementation WACallScreen {
	UIWindow *_window;
	UIImageView *_background;
	UIView *_lcd, *_bottom, *_grid;
	UILabel *_fallbackLabel;
	UIButton *_muteButton, *_speakerButton;
	NSDictionary *_call;
	NSString *_mode; // nil / ring-locked / ring-unlocked / call / video
	BOOL _minimized; // user left the call screen
	BOOL _greenBar; // green bar showing
	UIWindow *_ownBar;
	NSTimer *_tick;
}

+ (WACallScreen *)shared {
	static WACallScreen *s;
	if (!s) s = [[WACallScreen alloc] init];
	return s;
}

static void UpdatePosted(CFNotificationCenterRef c, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
	dispatch_async(dispatch_get_main_queue(), ^{ [[WACallScreen shared] update]; });
}

- (void)tell:(NSString *)what {
	notify_post([[@"com.aronsz26.wa4s.callscreen." stringByAppendingString:what] UTF8String]);
}

- (void)setMode:(NSString *)mode {
	if (mode == _mode) return;
	[_mode release];
	_mode = [mode copy];
}

#pragma mark - State from the app

- (void)update {
	NSDictionary *call = [NSDictionary dictionaryWithContentsOfFile:[kDir stringByAppendingPathComponent:@"callscreen.plist"]];
	NSString *state = Str(call, @"state") ?: @"none";
	CSLog(@"update: %@ (mode %@, locked %d)", state, _mode, DeviceLocked());
	BOOL sameCall = [[call objectForKey:@"id"] isEqual:[_call objectForKey:@"id"]];
	[_call release];
	_call = [call retain];
	if ([state isEqualToString:@"ringing"]) {
		if (![_mode isEqualToString:@"call"]) [self showRinging];
	} else if ([state isEqualToString:@"calling"] || [state isEqualToString:@"connecting"] || [state isEqualToString:@"active"]) {
		if (_minimized && sameCall) [self tick];
		else [self showCall];
	} else if ([state isEqualToString:@"video"]) {
		[self showVideo];
	} else if ([state isEqualToString:@"ended"] && _mode && sameCall) {
		[self ended];
	} else {
		[self hide];
	}
}

#pragma mark - Window

- (void)buildWindowIfNeeded {
	if (_window) return;
	CGRect screen = [UIScreen mainScreen].bounds;
	_window = [[UIWindow alloc] initWithFrame:screen];
	_window.windowLevel = 1050;
	// leave the status bar visible
	_window.backgroundColor = [UIColor clearColor];
	_background = [[UIImageView alloc] initWithFrame:CGRectMake(0, 20, screen.size.width, screen.size.height - 20)];
	_background.contentMode = UIViewContentModeScaleAspectFill;
	_background.clipsToBounds = YES;
	[_window addSubview:_background];
}

- (void)clear {
	[_lcd removeFromSuperview];
	[_lcd release];
	_lcd = nil;
	_fallbackLabel = nil;
	[_bottom removeFromSuperview];
	_bottom = nil;
	[_grid removeFromSuperview];
	_grid = nil;
	_muteButton = _speakerButton = nil;
}

- (UIImage *)picture {
	return [UIImage imageWithContentsOfFile:[kDir stringByAppendingPathComponent:@"callscreen.jpg"]];
}

- (void)fillTop:(NSString *)label {
	CGFloat w = _window.bounds.size.width;
	NSString *name = [Str(_call, @"name") length] ? Str(_call, @"name") : @"WhatsApp";
	Class lcdClass = objc_getClass("TPLCDView");
	if (lcdClass) {
		id lcd = ((id (*)(id, SEL, int))objc_msgSend)([lcdClass alloc], sel_registerName("initWithDefaultSizeForOrientation:"), 1);
		CGRect f = [lcd frame];
		f.origin.y = 20;
		f.size.width = w;
		[lcd setFrame:f];
		SendObject(lcd, "setText:", name);
		SendObject(lcd, "setLabel:", label);
		UIImage *pic = [_mode hasPrefix:@"ring"] ? [self picture] : nil;
		if (pic) SendObject(lcd, "setSubImage:", pic);
		_lcd = lcd;
	} else {
		_lcd = [[UIView alloc] initWithFrame:CGRectMake(0, 20, w, 96)];
		_lcd.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
		UILabel *n = [[[UILabel alloc] initWithFrame:CGRectMake(10, 10, w - 20, 34)] autorelease];
		n.font = [UIFont boldSystemFontOfSize:28];
		n.text = name;
		_fallbackLabel = [[[UILabel alloc] initWithFrame:CGRectMake(10, 48, w - 20, 22)] autorelease];
		_fallbackLabel.font = [UIFont systemFontOfSize:17];
		_fallbackLabel.text = label;
		for (UILabel *l in [NSArray arrayWithObjects:n, _fallbackLabel, nil]) {
			l.textAlignment = NSTextAlignmentCenter;
			l.textColor = [UIColor whiteColor];
			l.backgroundColor = [UIColor clearColor];
			[_lcd addSubview:l];
		}
	}
	[_window addSubview:_lcd];
}

- (void)setLabel:(NSString *)label {
	if ([_lcd respondsToSelector:sel_registerName("setLabel:")]) SendObject(_lcd, "setLabel:", label);
	else _fallbackLabel.text = label;
}

- (void)setBottom:(UIView *)bar {
	[_bottom removeFromSuperview];
	_bottom = bar;
	CGRect f = bar.frame;
	f.origin.y = _window.bounds.size.height - f.size.height;
	f.size.width = _window.bounds.size.width;
	bar.frame = f;
	[_window addSubview:bar];
	[bar release];
}

// own buttons for ios 4 (no ready bar there)
- (UIButton *)button:(NSString *)image title:(NSString *)title frame:(CGRect)frame action:(SEL)action {
	UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
	b.frame = frame;
	UIEdgeInsets caps = UIEdgeInsetsMake(0, 14, 0, 14);
	UIImage *normal = SystemImage(kTelephonyUI, image), *pressed = SystemImage(kTelephonyUI, [image stringByAppendingString:@"_pressed"]);
	if (normal) {
		[b setBackgroundImage:Stretch(normal, caps) forState:UIControlStateNormal];
		if (pressed) [b setBackgroundImage:Stretch(pressed, caps) forState:UIControlStateHighlighted];
	} else {
		b.backgroundColor = [image hasSuffix:@"red"] ? [UIColor colorWithRed:0.8 green:0.15 blue:0.15 alpha:1]
			: [UIColor colorWithRed:0.2 green:0.65 blue:0.25 alpha:1];
	}
	[b setTitle:title forState:UIControlStateNormal];
	b.titleLabel.font = [UIFont boldSystemFontOfSize:20];
	b.titleLabel.shadowOffset = CGSizeMake(0, -1);
	[b setTitleShadowColor:[UIColor colorWithWhite:0 alpha:0.5] forState:UIControlStateNormal];
	[b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
	return b;
}

- (UIView *)plainBar {
	UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _window.bounds.size.width, 96)];
	bar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
	return bar;
}

- (void)showWindow {
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hide) object:nil];
	// one level above the lock screen alert window
	UIWindow *lockWindow = [Send(AwayController(), "awayView") window];
	_window.windowLevel = MAX(1050, lockWindow ? lockWindow.windowLevel + 1 : 0);
	_window.hidden = NO;
	if (!_tick) _tick = [[NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick) userInfo:nil repeats:YES] retain];
	[self wake];
}

#pragma mark - Ringing

- (void)showRinging {
	BOOL locked = DeviceLocked();
	NSString *mode = locked ? @"ring-locked" : @"ring-unlocked";
	if ([_mode isEqualToString:mode] && _window && !_window.hidden) return;
	[self setMode:mode];
	[self buildWindowIfNeeded];
	[self clear];
	_background.image = LockWallpaper() ?: CallBackground(_window.bounds.size.height);
	[self fillTop:[[_call objectForKey:@"video"] boolValue] ? @"WhatsApp Video" : @"WhatsApp"];
	CGFloat w = _window.bounds.size.width;
	if (locked) {
		Class lockClass = objc_getClass("TPBottomLockBar");
		CGSize size = ClassSize(lockClass, "defaultSize");
		if (size.height > 0) {
			id bar = ((id (*)(id, SEL, CGRect))objc_msgSend)([lockClass alloc], sel_registerName("initForIncomingCallWithFrame:"),
				CGRectMake(0, 0, w, size.height));
			SendObject(bar, "setDelegate:", self);
			SendObject(bar, "setLabel:", @"slide to answer"); // starts empty, set the text ourselves
			[self setBottom:bar];
			Send(bar, "startAnimating");
		} else { // no lock bar -> big answer button
			UIView *bar = [self plainBar];
			[bar addSubview:[self button:@"bottombargreen" title:@"Answer" frame:CGRectMake(18, 24, w - 36, 47) action:@selector(answer)]];
			[self setBottom:bar];
		}
	} else {
		Class dual = objc_getClass("TPBottomDoubleButtonBar");
		if (dual) {
			CGFloat h = ClassFloat(objc_getClass("TPBottomBar"), "defaultHeight", 96);
			id bar = ((id (*)(id, SEL, CGRect))objc_msgSend)([dual alloc], sel_registerName("initForIncomingCallWithFrame:"),
				CGRectMake(0, 0, w, h));
			[Send(bar, "button") addTarget:self action:@selector(decline) forControlEvents:UIControlEventTouchUpInside];
			[Send(bar, "button2") addTarget:self action:@selector(answer) forControlEvents:UIControlEventTouchUpInside];
			[self setBottom:bar];
		} else {
			UIView *bar = [self plainBar];
			CGFloat half = floorf((w - 36 - 10) / 2);
			[bar addSubview:[self button:@"bottombarred" title:@"Decline" frame:CGRectMake(18, 24, half, 47) action:@selector(decline)]];
			[bar addSubview:[self button:@"bottombargreen" title:@"Answer" frame:CGRectMake(w - 18 - half, 24, half, 47) action:@selector(answer)]];
			[self setBottom:bar];
		}
	}
	[self showWindow];
}

#pragma mark - In the call

// the 6 buttons, only mute + speaker do something
- (UIView *)buttonGrid {
	CGFloat colW[3] = {96, 91, 97}, rowH[2] = {107, 115};
	UIView *grid = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, colW[0] + colW[1] + colW[2], rowH[0] + rowH[1])] autorelease];
	NSArray *glyphs = [NSArray arrayWithObjects:@"mute", @"dialer", @"speaker", @"addcall", @"hold", @"contacts", nil];
	NSArray *titles = [NSArray arrayWithObjects:@"mute", @"keypad", @"speaker", @"add call", @"hold", @"contacts", nil];
	for (int i = 0; i < 6; i++) {
		int col = i % 3, row = i / 3;
		CGFloat x = col == 0 ? 0 : (col == 1 ? colW[0] : colW[0] + colW[1]);
		UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
		b.frame = CGRectMake(x, row == 0 ? 0 : rowH[0], colW[col], rowH[row]);
		NSString *n = [NSString stringWithFormat:@"%d", i + 1];
		UIImage *bg = SystemImage(kPhoneApp, [@"sixsqbutton_" stringByAppendingString:n]);
		UIImage *sel = SystemImage(kPhoneApp, [@"sixsqbuttonsel_" stringByAppendingString:n]);
		[b setBackgroundImage:bg forState:UIControlStateNormal];
		[b setBackgroundImage:sel forState:UIControlStateHighlighted];
		[b setBackgroundImage:sel forState:UIControlStateSelected];
		[b setBackgroundImage:sel forState:UIControlStateSelected | UIControlStateHighlighted];
		if (!bg) {
			b.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.7];
			b.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:1].CGColor;
			b.layer.borderWidth = 0.5;
		}
		UIImage *glyph = SystemImage(kPhoneApp, [glyphs objectAtIndex:i]) ?: SystemImage(kTelephonyUI, [glyphs objectAtIndex:i]);
		UIImageView *gv = [[[UIImageView alloc] initWithImage:glyph] autorelease];
		gv.contentMode = UIViewContentModeCenter;
		gv.clipsToBounds = YES;
		gv.frame = CGRectMake(0, row == 0 ? 6 : 10, colW[col], 70);
		[b addSubview:gv];
		UILabel *l = [[[UILabel alloc] initWithFrame:CGRectMake(2, rowH[row] - (row == 0 ? 32 : 38), colW[col] - 4, 18)] autorelease];
		l.text = [titles objectAtIndex:i];
		l.font = [UIFont boldSystemFontOfSize:12];
		l.textColor = [UIColor whiteColor];
		l.backgroundColor = [UIColor clearColor];
		l.textAlignment = NSTextAlignmentCenter;
		l.shadowColor = [UIColor colorWithWhite:0 alpha:0.6];
		l.shadowOffset = CGSizeMake(0, -1);
		[b addSubview:l];
		if (i == 0) {
			_muteButton = b;
			[b addTarget:self action:@selector(toggleMute) forControlEvents:UIControlEventTouchUpInside];
		} else if (i == 2) {
			_speakerButton = b;
			[b addTarget:self action:@selector(toggleSpeaker) forControlEvents:UIControlEventTouchUpInside];
		} else {
			b.enabled = NO;
			gv.alpha = l.alpha = 0.35;
		}
		[grid addSubview:b];
	}
	return grid;
}

- (void)showCall {
	[self setGreenBar:NO];
	_minimized = NO;
	if (![_mode isEqualToString:@"call"] || !_window || _window.hidden) {
		[self setMode:@"call"];
		[self buildWindowIfNeeded];
		[self clear];
		_background.image = [self picture] ?: CallBackground(_window.bounds.size.height);
		[self fillTop:@""];
		CGFloat w = _window.bounds.size.width;
		Class single = objc_getClass("TPBottomSingleButtonBar");
		if (single && [single instancesRespondToSelector:sel_registerName("initForEndCallWithFrame:")]) {
			CGFloat bh = ClassFloat(objc_getClass("TPBottomBar"), "defaultHeight", 96);
			id bar = ((id (*)(id, SEL, CGRect))objc_msgSend)([single alloc], sel_registerName("initForEndCallWithFrame:"),
				CGRectMake(0, 0, w, bh));
			[Send(bar, "button") addTarget:self action:@selector(hangup) forControlEvents:UIControlEventTouchUpInside];
			[self setBottom:bar];
		} else {
			UIView *bar = [self plainBar];
			[bar addSubview:[self button:@"bottombarred" title:@"End" frame:CGRectMake(18, 24, w - 36, 47) action:@selector(hangup)]];
			[self setBottom:bar];
		}
		_grid = [self buttonGrid];
		CGFloat top = CGRectGetMaxY(_lcd.frame), bottom = _bottom.frame.origin.y;
		_grid.frame = CGRectMake(floorf((w - _grid.bounds.size.width) / 2),
			floorf(top + (bottom - top - _grid.bounds.size.height) / 2), _grid.bounds.size.width, _grid.bounds.size.height);
		[_window addSubview:_grid];
		[self showWindow];
	}
	[self tick];
}

#pragma mark - Video calls

// video runs in the app. locked we stay here (audio only) until unlock
- (void)showVideo {
	if (DeviceLocked()) {
		if (![_mode isEqualToString:@"call"] || !_window || _window.hidden) [self showCall];
		return;
	}
	if (![_mode isEqualToString:@"video"]) {
		[self hide];
		[self setMode:@"video"];
		CSLog(@"video call: to the app");
		if (![[_call objectForKey:@"front"] boolValue]) [self openApp];
		return;
	}
	[self setGreenBar:![[_call objectForKey:@"front"] boolValue]];
}

- (void)openApp {
	NSString *bundle = Str(_call, @"bundle");
	UIApplication *sb = [UIApplication sharedApplication];
	SEL launch = sel_registerName("launchApplicationWithIdentifier:suspended:");
	if (!bundle.length || ![sb respondsToSelector:launch]) {
		CSLog(@"video call: can't open the app");
		return;
	}
	((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(sb, launch, bundle, NO);
}

- (void)ended {
	[self setGreenBar:NO];
	[UIDevice currentDevice].proximityMonitoringEnabled = NO;
	if (_minimized || !_window || _window.hidden) {
		[self hide];
		return;
	}
	[self setLabel:@"call ended"];
	[_bottom removeFromSuperview];
	_bottom = nil;
	_grid.userInteractionEnabled = NO;
	[self performSelector:@selector(hide) withObject:nil afterDelay:1.5];
}

- (void)hide {
	[self setMode:nil];
	_minimized = NO;
	[self setGreenBar:NO];
	[_tick invalidate];
	[_tick release];
	_tick = nil;
	_window.hidden = YES;
	[self clear];
	[UIDevice currentDevice].proximityMonitoringEnabled = NO;
	// springboard fades the lock clock out under our window and only brings it back on the next wake
	if (DeviceLocked()) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{ ShowLockClock(); });
}

- (NSString *)timeText {
	double since = [[_call objectForKey:@"activeSince"] doubleValue];
	if (since <= 0) {
		NSString *state = Str(_call, @"state");
		if ([state isEqualToString:@"calling"]) return [[_call objectForKey:@"callback"] boolValue] ? @"calling back..." : @"calling...";
		return @"connecting...";
	}
	int secs = (int)([[NSDate date] timeIntervalSince1970] - since);
	if (secs >= 3600) return [NSString stringWithFormat:@"%d:%02d:%02d", secs / 3600, secs / 60 % 60, secs % 60];
	return [NSString stringWithFormat:@"%02d:%02d", secs / 60, secs % 60];
}

// tick every sec: timer, mute/speaker, keep screen on, proximity
- (void)tick {
	if ([_mode isEqualToString:@"call"] && [Str(_call, @"state") isEqualToString:@"video"] && !DeviceLocked()) {
		[self showVideo];
		return;
	}
	if ([_mode isEqualToString:@"call"]) {
		[self setLabel:[self timeText]];
		BOOL speaker = [[_call objectForKey:@"speaker"] boolValue];
		_muteButton.selected = [[_call objectForKey:@"muted"] boolValue];
		_speakerButton.selected = speaker;
		[UIDevice currentDevice].proximityMonitoringEnabled = !_minimized && !speaker;
	} else if ([_mode hasPrefix:@"ring"]) {
		[self wake];
		if ([_mode isEqualToString:@"ring-locked"] && !DeviceLocked()) [self showRinging];
	}
}

// wake the screen. locked: the lock screen's own undim, otherwise the top bar with the clock stays faded out.
// ios 6 also resetIdleTimerAndUndim + backlight
- (void)wake {
	id away = AwayController();
	UIApplication *sb = [UIApplication sharedApplication];
	if (SendBool(away, "isDimmed")) Send(away, "undimScreen");
	SEL undim = sel_registerName("resetIdleTimerAndUndim:");
	if ([sb respondsToSelector:undim]) ((void (*)(id, SEL, BOOL))objc_msgSend)(sb, undim, YES);
	SEL backlight = sel_registerName("setBacklightFactor:");
	if ([sb respondsToSelector:backlight]) ((void (*)(id, SEL, float))objc_msgSend)(sb, backlight, 1.0f);
	Send(away, "restartDimTimer");
}

#pragma mark - Leaving and returning (Home button, green bar)

// green bar (own one on ios 4)
- (void)setGreenBar:(BOOL)on {
	if (on == _greenBar) return;
	_greenBar = on;
	id data = Send(objc_getClass("SBStatusBarDataManager"), "sharedDataManager");
	if ([data respondsToSelector:sel_registerName("toggleSimulatesInCallStatusBar")]) {
		Send(data, "toggleSimulatesInCallStatusBar");
		return;
	}
	if (on && !_ownBar) {
		CGFloat w = [UIScreen mainScreen].bounds.size.width;
		_ownBar = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, w, 20)];
		_ownBar.windowLevel = 1100;
		_ownBar.backgroundColor = [UIColor colorWithRed:0.30 green:0.72 blue:0.25 alpha:1];
		UILabel *l = [[[UILabel alloc] initWithFrame:_ownBar.bounds] autorelease];
		l.text = @"Touch to return to call";
		l.font = [UIFont boldSystemFontOfSize:13];
		l.textColor = [UIColor whiteColor];
		l.backgroundColor = [UIColor clearColor];
		l.textAlignment = NSTextAlignmentCenter;
		[_ownBar addSubview:l];
		UITapGestureRecognizer *tap = [[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(returnToCall)] autorelease];
		[_ownBar addGestureRecognizer:tap];
	}
	_ownBar.hidden = !on;
}

// home during a call -> call keeps going in bg. YES = handled
- (BOOL)homePressed {
	if (![_mode isEqualToString:@"call"] || _minimized || !_window || _window.hidden || DeviceLocked()) return NO;
	_minimized = YES;
	_window.hidden = YES;
	[UIDevice currentDevice].proximityMonitoringEnabled = NO;
	[self setGreenBar:YES];
	return YES;
}

// green bar tapped
- (BOOL)returnToCall {
	if ([_mode isEqualToString:@"video"] && _greenBar) {
		[self setGreenBar:NO];
		[self openApp];
		return YES;
	}
	if (!_minimized) return NO;
	[self showCall];
	return YES;
}

#pragma mark - Choices

- (void)answer {
	[self tell:@"answer"];
	[self showCall];
}

- (void)decline {
	[self tell:@"decline"];
	[self hide];
}

- (void)hangup {
	[self tell:@"hangup"];
	[self ended];
}

- (void)toggleMute {
	BOOL on = !_muteButton.selected;
	_muteButton.selected = on;
	[self tell:on ? @"mute" : @"unmute"];
}

- (void)toggleSpeaker {
	BOOL on = !_speakerButton.selected;
	_speakerButton.selected = on;
	[UIDevice currentDevice].proximityMonitoringEnabled = !on;
	[self tell:on ? @"speaker" : @"earpiece"];
}

#pragma mark - TPBottomLockBar delegate

- (void)lockBarUnlocked:(id)bar {
	[self answer];
}

- (void)lockBarUnlocked:(id)bar freezeKnobInLockedPosition:(BOOL)freeze {
	[self answer];
}

- (void)lockBarStartedTracking:(id)bar {
}

- (void)lockBarStoppedTracking:(id)bar {
}

- (void)lockBarSlidBackToOrigin:(id)bar {
}

- (void)lockBar:(id)bar textAlphaChangedForKnobDrag:(float)alpha {
}

@end

#pragma mark - SpringBoard hooks

static void (*OrigMenuUp)(id, SEL, void *);
static void (*OrigReturnTap)(id, SEL, id);
static void (*OrigWorkspaceReturn)(id, SEL, id, id, id);

static void MenuUp(id self, SEL cmd, void *event) {
	[[WACallScreen shared] homePressed];
	if (OrigMenuUp) OrigMenuUp(self, cmd, event);
}

// green bar on home screen
static void ReturnTap(id self, SEL cmd, id arg) {
	if (![[WACallScreen shared] returnToCall] && OrigReturnTap) OrigReturnTap(self, cmd, arg);
}

// green bar inside an app
static void WorkspaceReturn(id self, SEL cmd, id workspace, id app, id style) {
	if (![[WACallScreen shared] returnToCall] && OrigWorkspaceReturn) OrigWorkspaceReturn(self, cmd, workspace, app, style);
}

// swiping the app away turns off SBApplicationAutoLaunchForVoIP -> no relaunch, no calls.
// just keep it on (whatsapp itself always has it)
static void (*OrigSetAutoLaunchForVoIP)(id, SEL, BOOL);

// ios still skips the relaunch sometimes (app was busy when swiped, low memory),
// so look again and start it ourselves if it's gone
static void RelaunchCheck(id app, NSString *bundle, int tries) {
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 5), dispatch_get_main_queue(), ^{
		if (![app respondsToSelector:sel_registerName("isRunning")] || SendBool(app, "isRunning")) return;
		CSLog(@"VoIP relaunch: still gone, starting %@ ourselves", bundle);
		UIApplication *sb = [UIApplication sharedApplication];
		SEL launch = sel_registerName("launchApplicationWithIdentifier:suspended:");
		SEL boot = sel_registerName("autoLaunchIfNecessaryOnBootOrInstall:");
		if ([sb respondsToSelector:launch]) ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(sb, launch, bundle, YES);
		else if ([app respondsToSelector:boot]) ((void (*)(id, SEL, BOOL))objc_msgSend)(app, boot, YES);
		if (tries > 1) RelaunchCheck(app, bundle, tries - 1);
	});
}

static void SetAutoLaunchForVoIP(id self, SEL cmd, BOOL on) {
	NSString *bundle = Send(self, "bundleIdentifier") ?: Send(self, "displayIdentifier");
	if (!on && [bundle hasPrefix:@"com.aronsz26.wa4s"]) {
		CSLog(@"VoIP relaunch kept on for %@", bundle);
		on = YES;
		RelaunchCheck(self, bundle, 3);
	}
	OrigSetAutoLaunchForVoIP(self, cmd, on);
}

// ios 4/5: after swiping away springboard tries the voip relaunch but never starts the app.
// the boot path does, so take that one
static void (*OrigRelaunchIfNeeded)(id, SEL);

static void RelaunchIfNeeded(id self, SEL cmd) {
	OrigRelaunchIfNeeded(self, cmd);
	NSString *bundle = Send(self, "bundleIdentifier") ?: Send(self, "displayIdentifier");
	SEL boot = sel_registerName("autoLaunchIfNecessaryOnBootOrInstall:");
	if (![bundle hasPrefix:@"com.aronsz26.wa4s"] || !SendBool(self, "_shouldAutoLaunchForVoIP")
		|| ![self respondsToSelector:sel_registerName("process")] || ![self respondsToSelector:boot]) return;
	id app = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 2), dispatch_get_main_queue(), ^{
		if (Send(app, "process")) return;
		CSLog(@"VoIP relaunch: starting %@ ourselves", bundle);
		((void (*)(id, SEL, BOOL))objc_msgSend)(app, boot, YES);
	});
}

// ios 5/6: springboard only makes a notification provider for apps outside /Applications,
// without one there are badges but no banners
static id (*OrigAllPushBundleIDs)(id, SEL);

static id AllPushBundleIDs(id self, SEL cmd) {
	NSArray *ids = OrigAllPushBundleIDs(self, cmd);
	NSString *own = @"com.aronsz26.wa4s";
	return [ids containsObject:own] ? ids : [(ids ?: @[]) arrayByAddingObject:own];
}

static IMP Hook(const char *cls, const char *sel, IMP replacement) {
	Method m = class_getInstanceMethod(objc_getClass(cls), sel_registerName(sel));
	return m ? method_setImplementation(m, replacement) : NULL;
}

__attribute__((constructor)) static void WACallScreenStart(void) {
	@autoreleasepool { // no pool yet when substrate loads us
	dlopen("/System/Library/PrivateFrameworks/TelephonyUI.framework/TelephonyUI", RTLD_LAZY);
	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, UpdatePosted,
		CFSTR("com.aronsz26.wa4s.callscreen.update"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	OrigMenuUp = (void (*)(id, SEL, void *))Hook("SpringBoard", "menuButtonUp:", (IMP)MenuUp);
	OrigReturnTap = (void (*)(id, SEL, id))Hook("SpringBoard", "statusBarReturnActionTap:", (IMP)ReturnTap);
	OrigWorkspaceReturn = (void (*)(id, SEL, id, id, id))Hook("SBWorkspace",
		"workspace:handleStatusBarReturnActionFromApplication:statusBarStyle:", (IMP)WorkspaceReturn);
	OrigSetAutoLaunchForVoIP = (void (*)(id, SEL, BOOL))Hook("SBApplication", "_setAutoLaunchForVoIP:",
		(IMP)SetAutoLaunchForVoIP);
	OrigAllPushBundleIDs = (id (*)(id, SEL))Hook("SBRemoteNotificationServer", "_allPushRegisteredThirdPartyBundleIDs",
		(IMP)AllPushBundleIDs);
	CSLog(@"loaded: VoIP relaunch hook %d, banner hook %d", OrigSetAutoLaunchForVoIP != NULL, OrigAllPushBundleIDs != NULL);
	OrigRelaunchIfNeeded = (void (*)(id, SEL))Hook("SBApplication", "_relaunchAfterExitIfNecessary", (IMP)RelaunchIfNeeded);
	CSLog(@"loaded: home hook %d, return hooks %d/%d, lock bar %d, LCD %d, button bar %d, green bar %d",
		OrigMenuUp != NULL, OrigReturnTap != NULL, OrigWorkspaceReturn != NULL, objc_getClass("TPBottomLockBar") != nil,
		objc_getClass("TPLCDView") != nil, objc_getClass("TPBottomDoubleButtonBar") != nil,
		[objc_getClass("SBStatusBarDataManager") instancesRespondToSelector:sel_registerName("toggleSimulatesInCallStatusBar")]);
	}
}
