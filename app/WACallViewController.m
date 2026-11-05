#import <QuartzCore/QuartzCore.h>
#import "WACallViewController.h"
#import "WACall.h"
#import "WAAssets.h"
#import "WAClient.h"
#import "WAVideoCallViewController.h"

static NSString *const kTelephonyUI = @"/System/Library/PrivateFrameworks/TelephonyUI.framework";
static NSString *const kPhoneApp = @"/Applications/MobilePhone.app";

// phone app graphics
static UIImage *PhoneImg(NSString *dir, NSString *name) {
	return WASystemImg([dir stringByAppendingPathComponent:name]);
}

static WACallViewController *current;

@implementation WACallViewController {
	UIImageView *_background;
	UILabel *_nameLabel, *_statusLabel;
	UIView *_grid;
	UIButton *_muteButton, *_speakerButton;
	UIButton *_endButton, *_declineButton, *_answerButton;
	NSTimer *_clock;
	BOOL _closing;
}

+ (BOOL)showing {
	return current != nil;
}

+ (void)showIfNeededInWindow:(UIWindow *)window {
	if (current || ![WACall shared].live || [WACall systemCallScreen]) return; // springboard handles it
	if ([WAVideoCallViewController wanted]) return; // video screen handles it
	UIViewController *top = window.rootViewController;
	while (top.presentedViewController) top = top.presentedViewController;
	current = [[WACallViewController alloc] init];
	[top presentViewController:current animated:YES completion:nil];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.wantsFullScreenLayout = YES;
	UIView *v = self.view;
	v.backgroundColor = [UIColor blackColor];
	CGFloat W = v.bounds.size.width, H = v.bounds.size.height;

	// avatar fullscreen or dark bg
	_background = [[UIImageView alloc] initWithFrame:v.bounds];
	_background.contentMode = UIViewContentModeScaleAspectFill;
	_background.clipsToBounds = YES;
	_background.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_background.image = [self fallbackBackground];
	[v addSubview:_background];
	NSString *peer = [WACall shared].info[@"peer"];
	UIImage *pic = [[WAClient shared] cachedAvatarFor:peer];
	if (pic) _background.image = pic;
	else if (peer.length) [[WAClient shared] avatarFor:peer completion:^(UIImage *image) {
		if (image) self->_background.image = image;
	}];

	// lcd bar
	UIImageView *lcd = [[UIImageView alloc] initWithFrame:CGRectMake(0, 20, W, 96)];
	lcd.image = [PhoneImg(kPhoneApp, @"lcd_top") resizableImageWithCapInsets:UIEdgeInsetsMake(0, 3, 0, 3)];
	if (!lcd.image) lcd.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
	lcd.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[v addSubview:lcd];
	_nameLabel = [self label:[UIFont boldSystemFontOfSize:26] frame:CGRectMake(10, 30, W - 20, 34)];
	_statusLabel = [self label:[UIFont systemFontOfSize:17] frame:CGRectMake(10, 66, W - 20, 22)];
	_statusLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1];
	_nameLabel.adjustsFontSizeToFitWidth = YES;
	_nameLabel.minimumScaleFactor = 0.6;

	// 6 buttons, only mute + speaker work
	CGFloat colW[3] = {96, 91, 97}, rowH[2] = {107, 115};
	CGFloat gw = colW[0] + colW[1] + colW[2], gh = rowH[0] + rowH[1];
	CGFloat barTop = H - 79;
	_grid = [[UIView alloc] initWithFrame:CGRectMake(floorf((W - gw) / 2), floorf(116 + (barTop - 116 - gh) / 2), gw, gh)];
	_grid.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
	[v addSubview:_grid];
	NSArray *glyphs = @[@"mute", @"dialer", @"speaker", @"addcall", @"hold", @"contacts"];
	NSArray *titles = @[@"mute", @"keypad", @"speaker", @"add call", @"hold", @"contacts"];
	for (int i = 0; i < 6; i++) {
		int col = i % 3, row = i / 3;
		CGFloat x = col == 0 ? 0 : (col == 1 ? colW[0] : colW[0] + colW[1]);
		CGFloat y = row == 0 ? 0 : rowH[0];
		UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
		b.frame = CGRectMake(x, y, colW[col], rowH[row]);
		NSString *n = [NSString stringWithFormat:@"%d", i + 1];
		UIImage *bg = PhoneImg(kPhoneApp, [@"sixsqbutton_" stringByAppendingString:n]);
		UIImage *sel = PhoneImg(kPhoneApp, [@"sixsqbuttonsel_" stringByAppendingString:n]);
		[b setBackgroundImage:bg forState:UIControlStateNormal];
		[b setBackgroundImage:sel forState:UIControlStateHighlighted];
		[b setBackgroundImage:sel forState:UIControlStateSelected];
		[b setBackgroundImage:sel forState:UIControlStateSelected | UIControlStateHighlighted];
		if (!bg) {
			b.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.7];
			b.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:1].CGColor;
			b.layer.borderWidth = 0.5;
		}
		UIImage *glyph = PhoneImg(kPhoneApp, glyphs[i]) ?: PhoneImg(kTelephonyUI, glyphs[i]);
		UIImageView *gv = [[UIImageView alloc] initWithImage:glyph];
		gv.contentMode = UIViewContentModeCenter;
		gv.clipsToBounds = YES;
		gv.frame = CGRectMake(0, row == 0 ? 6 : 10, colW[col], 70);
		[b addSubview:gv];
		UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(2, rowH[row] - (row == 0 ? 32 : 38), colW[col] - 4, 18)];
		l.text = titles[i];
		l.font = [UIFont boldSystemFontOfSize:12];
		l.textColor = [UIColor whiteColor];
		l.backgroundColor = [UIColor clearColor];
		l.textAlignment = NSTextAlignmentCenter;
		l.adjustsFontSizeToFitWidth = YES;
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
		[_grid addSubview:b];
	}

	// end / decline + answer
	UIImageView *bar = [[UIImageView alloc] initWithFrame:CGRectMake(0, barTop, W, 79)];
	bar.image = [self barBackground];
	bar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
	[v addSubview:bar];
	CGFloat by = barTop + 16;
	_endButton = [self barButton:@"bottombarred" title:@"End" glyph:@"decline" frame:CGRectMake(18, by, W - 36, 47)];
	[_endButton addTarget:self action:@selector(end) forControlEvents:UIControlEventTouchUpInside];
	CGFloat half = floorf((W - 36 - 10) / 2);
	_declineButton = [self barButton:@"bottombarred" title:@"Decline" glyph:nil frame:CGRectMake(18, by, half, 47)];
	[_declineButton addTarget:self action:@selector(end) forControlEvents:UIControlEventTouchUpInside];
	_answerButton = [self barButton:@"bottombargreen" title:@"Answer" glyph:nil frame:CGRectMake(W - 18 - half, by, half, 47)];
	[_answerButton addTarget:self action:@selector(answer) forControlEvents:UIControlEventTouchUpInside];
	for (UIButton *b in @[_endButton, _declineButton, _answerButton]) [v addSubview:b];

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(update) name:WACallChangedNotification object:nil];
	[self update];
}

- (UIImage *)fallbackBackground {
	UIGraphicsBeginImageContextWithOptions(CGSizeMake(1, 480), YES, 1);
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
	CGFloat comps[8] = {0.20, 0.23, 0.28, 1, 0.04, 0.05, 0.06, 1};
	CGGradientRef g = CGGradientCreateWithColorComponents(space, comps, NULL, 2);
	CGContextDrawLinearGradient(ctx, g, CGPointZero, CGPointMake(0, 480), 0);
	CGGradientRelease(g);
	CGColorSpaceRelease(space);
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

// dark glass bar
- (UIImage *)barBackground {
	UIGraphicsBeginImageContextWithOptions(CGSizeMake(1, 79), NO, 0);
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
	CGFloat comps[8] = {0.25, 0.26, 0.28, 0.92, 0.04, 0.04, 0.05, 0.96};
	CGGradientRef g = CGGradientCreateWithColorComponents(space, comps, NULL, 2);
	CGContextDrawLinearGradient(ctx, g, CGPointZero, CGPointMake(0, 79), 0);
	CGGradientRelease(g);
	CGColorSpaceRelease(space);
	CGContextSetRGBFillColor(ctx, 1, 1, 1, 0.25);
	CGContextFillRect(ctx, CGRectMake(0, 0, 1, 1));
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return [img resizableImageWithCapInsets:UIEdgeInsetsZero];
}

- (UILabel *)label:(UIFont *)font frame:(CGRect)frame {
	UILabel *l = [[UILabel alloc] initWithFrame:frame];
	l.font = font;
	l.textColor = [UIColor whiteColor];
	l.backgroundColor = [UIColor clearColor];
	l.textAlignment = NSTextAlignmentCenter;
	l.shadowColor = [UIColor colorWithWhite:0 alpha:0.7];
	l.shadowOffset = CGSizeMake(0, -1);
	l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[self.view addSubview:l];
	return l;
}

- (UIButton *)barButton:(NSString *)image title:(NSString *)title glyph:(NSString *)glyph frame:(CGRect)frame {
	UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
	b.frame = frame;
	UIEdgeInsets caps = UIEdgeInsetsMake(0, 14, 0, 14);
	UIImage *normal = [PhoneImg(kTelephonyUI, image) resizableImageWithCapInsets:caps];
	UIImage *pressed = [PhoneImg(kTelephonyUI, [image stringByAppendingString:@"_pressed"]) resizableImageWithCapInsets:caps];
	if (normal) {
		[b setBackgroundImage:normal forState:UIControlStateNormal];
		[b setBackgroundImage:pressed forState:UIControlStateHighlighted];
	} else {
		b.backgroundColor = [image hasSuffix:@"red"] ? [UIColor colorWithRed:0.8 green:0.15 blue:0.15 alpha:1]
			: [UIColor colorWithRed:0.2 green:0.65 blue:0.25 alpha:1];
		b.layer.cornerRadius = 8;
	}
	[b setTitle:title forState:UIControlStateNormal];
	b.titleLabel.font = [UIFont boldSystemFontOfSize:20];
	b.titleLabel.shadowOffset = CGSizeMake(0, -1);
	[b setTitleShadowColor:[UIColor colorWithWhite:0 alpha:0.5] forState:UIControlStateNormal];
	UIImage *g = glyph ? PhoneImg(kTelephonyUI, glyph) : nil;
	if (g) {
		[b setImage:g forState:UIControlStateNormal];
		b.imageEdgeInsets = UIEdgeInsetsMake(0, -10, 0, 10);
		b.titleEdgeInsets = UIEdgeInsetsMake(0, 0, 0, -10);
	}
	return b;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
	return UIStatusBarStyleBlackTranslucent;
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleBlackTranslucent animated:animated];
	_clock = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(update) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleDefault animated:animated];
	[UIDevice currentDevice].proximityMonitoringEnabled = NO;
	[_clock invalidate];
	_clock = nil;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)update {
	WACall *call = [WACall shared];
	NSDictionary *info = call.info;
	NSString *state = info[@"state"] ?: @"ended";
	_nameLabel.text = [info[@"name"] length] ? info[@"name"] : @"WhatsApp";
	BOOL ringing = [state isEqualToString:@"ringing"], ended = [state isEqualToString:@"ended"];
	if (ringing) _statusLabel.text = call.video || call.peerVideo ? @"WhatsApp video call" : @"WhatsApp voice call";
	else if ([state isEqualToString:@"calling"]) _statusLabel.text = [info[@"callback"] boolValue] ? @"calling back…" : @"calling…";
	else if ([state isEqualToString:@"connecting"]) _statusLabel.text = @"connecting…";
	else if ([state isEqualToString:@"active"]) {
		int secs = call.activeSince ? (int)-[call.activeSince timeIntervalSinceNow] : 0;
		_statusLabel.text = secs >= 3600 ? [NSString stringWithFormat:@"%d:%02d:%02d", secs / 3600, secs / 60 % 60, secs % 60]
			: [NSString stringWithFormat:@"%02d:%02d", secs / 60, secs % 60];
	} else _statusLabel.text = [self endText:info[@"reason"]];
	_grid.hidden = ringing;
	_endButton.hidden = ringing;
	_declineButton.hidden = _answerButton.hidden = !ringing;
	_endButton.enabled = !ended;
	// proximity, not while ringing or on speaker
	[UIDevice currentDevice].proximityMonitoringEnabled = !ringing && !ended && !call.speaker;
	_muteButton.selected = call.muted;
	_speakerButton.selected = call.speaker;
	if (!ended && !_closing && [WAVideoCallViewController wanted]) {
		_closing = YES;
		[self close];
		return;
	}
	if (ended && !_closing) {
		_closing = YES;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			[self close];
		});
	}
}

- (NSString *)endText:(NSString *)reason {
	reason = reason.lowercaseString;
	if ([reason rangeOfString:@"busy"].location != NSNotFound) return @"busy";
	if ([reason rangeOfString:@"reject"].location != NSNotFound || [reason rangeOfString:@"declin"].location != NSNotFound) return @"declined";
	if ([reason rangeOfString:@"timeout"].location != NSNotFound || [reason rangeOfString:@"unanswered"].location != NSNotFound) return @"no answer";
	if (reason.length && ![reason isEqualToString:@"local"] && [reason rangeOfString:@"hang"].location == NSNotFound
		&& [reason rangeOfString:@"terminate"].location == NSNotFound) {
		NSLog(@"WA4S call ended: %@", reason);
	}
	return @"call ended";
}

- (void)close {
	if (current != self) return;
	current = nil;
	[self.presentingViewController dismissViewControllerAnimated:YES completion:^{
		// maybe a new call came in
		[WACallViewController showIfNeededInWindow:[UIApplication sharedApplication].keyWindow];
		[WAVideoCallViewController showIfNeededInWindow:[UIApplication sharedApplication].keyWindow];
	}];
}

- (void)toggleMute {
	[WACall shared].muted = ![WACall shared].muted;
	[self update];
}

- (void)toggleSpeaker {
	[WACall shared].speaker = ![WACall shared].speaker;
	[self update];
}

- (void)answer {
	[[WACall shared] answer];
}

- (void)end {
	[[WACall shared] hangup];
}

@end
