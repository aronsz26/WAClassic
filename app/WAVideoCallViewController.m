#import <QuartzCore/QuartzCore.h>
#import "WAVideoCallViewController.h"
#import "WACallViewController.h"
#import "WACall.h"
#import "WAVideoCall.h"
#import "WAAssets.h"
#import "WAClient.h"

// facetime graphics if present, else drawn
static NSString *const kConference = @"/System/Library/PrivateFrameworks/Conference.framework";

static UIImage *FTImg(NSString *name) {
	return WASystemImg([kConference stringByAppendingPathComponent:name]);
}

static WAVideoCallViewController *current;

@implementation WAVideoCallViewController {
	UIImageView *_remote, *_placeholder;
	UIImageView *_pipFrame;
	UIView *_pip;
	AVCaptureVideoPreviewLayer *_preview;
	UILabel *_nameLabel, *_statusLabel, *_pipLabel;
	UIButton *_muteButton, *_endButton, *_switchButton;
	NSTimer *_clock;
	BOOL _closing, _gotPicture;
	int _deviceTurns; // quarter turns ccw
}

+ (BOOL)wanted {
	WACall *call = [WACall shared];
	return call.live && ![call.state isEqualToString:@"ringing"] && (call.video || call.peerVideo);
}

+ (void)showIfNeededInWindow:(UIWindow *)window {
	// voice screen calls us again once it's gone
	if (current || ![self wanted] || [WACallViewController showing]) return;
	UIViewController *top = window.rootViewController;
	while (top.presentedViewController) top = top.presentedViewController;
	current = [[WAVideoCallViewController alloc] init];
	[top presentViewController:current animated:YES completion:nil];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.wantsFullScreenLayout = YES;
	UIView *v = self.view;
	v.backgroundColor = [UIColor blackColor];
	CGFloat W = v.bounds.size.width, H = v.bounds.size.height;

	// darkened avatar until video arrives
	_placeholder = [[UIImageView alloc] initWithFrame:v.bounds];
	_placeholder.contentMode = UIViewContentModeScaleAspectFill;
	_placeholder.clipsToBounds = YES;
	_placeholder.alpha = 0.5;
	_placeholder.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[v addSubview:_placeholder];
	NSString *peer = [WACall shared].info[@"peer"];
	UIImage *pic = [[WAClient shared] cachedAvatarFor:peer];
	if (pic) _placeholder.image = pic;
	else if (peer.length) [[WAClient shared] avatarFor:peer completion:^(UIImage *image) {
		if (image) self->_placeholder.image = image;
	}];

	_remote = [[UIImageView alloc] initWithFrame:v.bounds];
	_remote.contentMode = UIViewContentModeScaleAspectFill;
	_remote.clipsToBounds = YES;
	_remote.hidden = YES;
	[v addSubview:_remote];

	// top band
	UIImageView *top = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, W, 90)];
	top.image = [FTImg(@"textOverlayBackgroundTop") resizableImageWithCapInsets:UIEdgeInsetsZero];
	if (!top.image) top.image = [self gradientFrom:0.7 to:0 height:90];
	top.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[v addSubview:top];
	_nameLabel = [self label:[UIFont boldSystemFontOfSize:22] frame:CGRectMake(10, 24, W - 20, 28)];
	_statusLabel = [self label:[UIFont systemFontOfSize:15] frame:CGRectMake(10, 52, W - 20, 20)];
	_statusLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1];

	// pip
	UIImage *frame = FTImg(@"pipFramePortrait");
	CGSize fs = frame ? frame.size : CGSizeMake(100, 130);
	CGFloat scale = 100 / fs.width; // smaller than facetime's 167
	CGRect pipRect = CGRectMake(W - fs.width * scale - 6, 80, fs.width * scale, fs.height * scale);
	_pip = [[UIView alloc] initWithFrame:CGRectInset(pipRect, 4 * scale + 2, 4 * scale + 2)];
	_pip.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1];
	_pip.clipsToBounds = YES;
	[v addSubview:_pip];
	_pipLabel = [[UILabel alloc] initWithFrame:_pip.bounds];
	_pipLabel.numberOfLines = 0;
	_pipLabel.textAlignment = NSTextAlignmentCenter;
	_pipLabel.font = [UIFont boldSystemFontOfSize:12];
	_pipLabel.textColor = [UIColor whiteColor];
	_pipLabel.backgroundColor = [UIColor clearColor];
	_pipLabel.text = @"Camera off\nTap to turn on";
	[_pip addSubview:_pipLabel];
	_pipFrame = [[UIImageView alloc] initWithFrame:pipRect];
	_pipFrame.image = frame;
	if (!frame) {
		_pipFrame.layer.borderColor = [UIColor whiteColor].CGColor;
		_pipFrame.layer.borderWidth = 2;
		_pipFrame.layer.cornerRadius = 4;
	}
	_pipFrame.userInteractionEnabled = YES;
	[_pipFrame addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleCamera)]];
	[v addSubview:_pipFrame];

	// mute | end | switch
	CGFloat barH = 44, y = H - barH;
	CGFloat sideW = 93, midW = W - 2 * sideW;
	_muteButton = [self barButton:@"barLeft" glyph:@"barMute" frame:CGRectMake(0, y, sideW, barH)];
	[_muteButton addTarget:self action:@selector(toggleMute) forControlEvents:UIControlEventTouchUpInside];
	_endButton = [self barButton:@"barRightPressRed" glyph:@"barDecline" frame:CGRectMake(sideW, y, midW, barH)];
	[_endButton setTitle:@" End" forState:UIControlStateNormal];
	[_endButton addTarget:self action:@selector(end) forControlEvents:UIControlEventTouchUpInside];
	if (!FTImg(@"barRightPressRed")) _endButton.backgroundColor = [UIColor colorWithRed:0.75 green:0.12 blue:0.12 alpha:1];
	_switchButton = [self barButton:@"barRight" glyph:@"barCamera" frame:CGRectMake(sideW + midW, y, sideW, barH)];
	[_switchButton addTarget:self action:@selector(switchCamera) forControlEvents:UIControlEventTouchUpInside];
	for (UIButton *b in @[_muteButton, _endButton, _switchButton]) {
		b.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
		[v addSubview:b];
	}

	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc addObserver:self selector:@selector(update) name:WACallChangedNotification object:nil];
	[nc addObserver:self selector:@selector(picture:) name:WAVideoPictureNotification object:nil];
	[[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
	[nc addObserver:self selector:@selector(deviceTurned) name:UIDeviceOrientationDidChangeNotification object:nil];
	[self deviceTurned];
	[self update];
}

- (UIImage *)gradientFrom:(CGFloat)a to:(CGFloat)b height:(CGFloat)h {
	UIGraphicsBeginImageContextWithOptions(CGSizeMake(1, h), NO, 0);
	CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
	CGFloat comps[8] = {0, 0, 0, a, 0, 0, 0, b};
	CGGradientRef g = CGGradientCreateWithColorComponents(space, comps, NULL, 2);
	CGContextDrawLinearGradient(UIGraphicsGetCurrentContext(), g, CGPointZero, CGPointMake(0, h), 0);
	CGGradientRelease(g);
	CGColorSpaceRelease(space);
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
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

- (UIButton *)barButton:(NSString *)image glyph:(NSString *)glyph frame:(CGRect)frame {
	UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
	b.frame = frame;
	UIEdgeInsets caps = UIEdgeInsetsMake(0, 6, 0, 6);
	UIImage *bg = [FTImg(image) resizableImageWithCapInsets:caps];
	NSString *pressed = [image isEqualToString:@"barRightPressRed"] ? nil : [image stringByAppendingString:@"Press"];
	if (bg) {
		[b setBackgroundImage:bg forState:UIControlStateNormal];
		UIImage *p = pressed ? [FTImg(pressed) resizableImageWithCapInsets:caps] : nil;
		if (p) {
			[b setBackgroundImage:p forState:UIControlStateHighlighted];
			[b setBackgroundImage:p forState:UIControlStateSelected];
		}
	} else {
		b.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.9];
		b.layer.borderColor = [UIColor colorWithWhite:0.4 alpha:1].CGColor;
		b.layer.borderWidth = 0.5;
	}
	UIImage *g = FTImg(glyph);
	if (g) [b setImage:g forState:UIControlStateNormal];
	else [b setTitle:[glyph isEqualToString:@"barMute"] ? @"mute" : ([glyph isEqualToString:@"barCamera"] ? @"flip" : @"") forState:UIControlStateNormal];
	b.titleLabel.font = [UIFont boldSystemFontOfSize:18];
	b.titleLabel.shadowOffset = CGSizeMake(0, -1);
	[b setTitleShadowColor:[UIColor colorWithWhite:0 alpha:0.5] forState:UIControlStateNormal];
	return b;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
	return UIStatusBarStyleBlackTranslucent;
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleBlackTranslucent animated:animated];
	[UIApplication sharedApplication].idleTimerDisabled = YES;
	_clock = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(update) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleDefault animated:animated];
	[UIApplication sharedApplication].idleTimerDisabled = NO;
	[_clock invalidate];
	_clock = nil;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
}

// ui stays portrait, rotate the peer image instead
- (void)deviceTurned {
	int turns;
	switch ([UIDevice currentDevice].orientation) {
		case UIDeviceOrientationPortrait: turns = 0; break;
		case UIDeviceOrientationLandscapeLeft: turns = 1; break;
		case UIDeviceOrientationPortraitUpsideDown: turns = 2; break;
		case UIDeviceOrientationLandscapeRight: turns = 3; break;
		default: return;
	}
	if (turns == _deviceTurns) return;
	_deviceTurns = turns;
	[UIView animateWithDuration:0.3 animations:^{ [self layoutRemote]; }];
}

- (void)picture:(NSNotification *)note {
	UIImage *image = note.userInfo[@"image"];
	if (!image) return;
	_remote.image = image;
	if (!_gotPicture) {
		_gotPicture = YES;
		[self layoutRemote];
	}
}

// rotate by peer orientation and our own. fit when sideways, fill otherwise
- (void)layoutRemote {
	WACall *call = [WACall shared];
	CGRect b = self.view.bounds;
	int turns = (call.orientation + _deviceTurns) & 3;
	_remote.transform = CGAffineTransformIdentity;
	_remote.bounds = turns % 2 ? CGRectMake(0, 0, b.size.height, b.size.width) : b;
	_remote.center = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
	_remote.contentMode = turns % 2 ? UIViewContentModeScaleAspectFill : UIViewContentModeScaleAspectFit;
	_remote.transform = CGAffineTransformMakeRotation(turns * M_PI_2);
	_remote.hidden = !_gotPicture || !call.peerVideo;
}

- (void)update {
	WACall *call = [WACall shared];
	NSDictionary *info = call.info;
	NSString *state = info[@"state"] ?: @"ended";
	BOOL ended = [state isEqualToString:@"ended"];
	_nameLabel.text = [info[@"name"] length] ? info[@"name"] : @"WhatsApp";
	if ([state isEqualToString:@"calling"]) _statusLabel.text = [info[@"callback"] boolValue] ? @"calling back…" : @"WhatsApp video…";
	else if ([state isEqualToString:@"connecting"]) _statusLabel.text = @"connecting…";
	else if ([state isEqualToString:@"active"]) {
		int secs = call.activeSince ? (int)-[call.activeSince timeIntervalSinceNow] : 0;
		_statusLabel.text = secs >= 3600 ? [NSString stringWithFormat:@"%d:%02d:%02d", secs / 3600, secs / 60 % 60, secs % 60]
			: [NSString stringWithFormat:@"%02d:%02d", secs / 60, secs % 60];
		if (!call.peerVideo) _statusLabel.text = [_statusLabel.text stringByAppendingString:@" · camera off"];
	} else _statusLabel.text = @"call ended";
	[self layoutRemote];
	AVCaptureSession *session = [WAVideoCall shared].session;
	if (session && _preview.session != session) {
		[_preview removeFromSuperlayer];
		_preview = [AVCaptureVideoPreviewLayer layerWithSession:session];
		_preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
		_preview.frame = _pip.bounds;
		[_pip.layer insertSublayer:_preview atIndex:0];
	} else if (!session && _preview) {
		[_preview removeFromSuperlayer];
		_preview = nil;
	}
	_pipLabel.hidden = call.video;
	_muteButton.selected = call.muted;
	_switchButton.enabled = call.video && [WAVideoCall shared].canSwitchCamera;
	_switchButton.alpha = _switchButton.enabled ? 1 : 0.4;
	_endButton.enabled = !ended;
	if (ended && !_closing) {
		_closing = YES;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			[self close];
		});
	} else if (!ended && ![WAVideoCallViewController wanted] && !_closing) {
		// no video left -> voice call
		_closing = YES;
		[self close];
	}
}

- (void)close {
	if (current != self) return;
	current = nil;
	[self.presentingViewController dismissViewControllerAnimated:YES completion:^{
		[WACallViewController showIfNeededInWindow:[UIApplication sharedApplication].keyWindow];
		[WAVideoCallViewController showIfNeededInWindow:[UIApplication sharedApplication].keyWindow];
	}];
}

- (void)toggleMute {
	[WACall shared].muted = ![WACall shared].muted;
	[self update];
}

- (void)toggleCamera {
	WACall *call = [WACall shared];
	if (![call.state isEqualToString:@"active"] && ![call.state isEqualToString:@"connecting"]) return;
	[call setCameraOn:!call.video];
}

// flip like facetime
- (void)switchCamera {
	WAVideoCall *video = [WAVideoCall shared];
	UIViewAnimationOptions flip = video.frontCamera ? UIViewAnimationOptionTransitionFlipFromLeft : UIViewAnimationOptionTransitionFlipFromRight;
	[UIView transitionWithView:_pip duration:0.5 options:flip animations:^{ [video switchCamera]; } completion:nil];
}

- (void)end {
	[[WACall shared] hangup];
}

@end
