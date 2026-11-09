#import <QuartzCore/QuartzCore.h>
#import "WAHello.h"
#import "WASetupViewController.h"
#import "WADiag.h"
#import "WAAssets.h"
#import "WAUtil.h"

#pragma mark - Graphics

static UIImage *SetupImg(NSString *name) {
	for (NSString *dir in @[@"/Applications/Setup.app/", @"/System/Library/CoreServices/SpringBoard.app/Buddy"]) {
		UIImage *img = WASystemImg([dir stringByAppendingString:name]);
		if (img) return img;
	}
	return nil;
}

static UIImage *TelephonyImg(NSString *name) {
	return WASystemImg([@"/System/Library/PrivateFrameworks/TelephonyUI.framework/" stringByAppendingString:name]);
}

// ios 4 has no linen: grey with fine threads
static UIImage *DrawnLinen(void) {
	CGSize size = CGSizeMake(320, 568);
	UIGraphicsBeginImageContextWithOptions(size, YES, 0);
	CGContextRef c = UIGraphicsGetCurrentContext();
	[WAColor(0x6C6E71) setFill];
	CGContextFillRect(c, CGRectMake(0, 0, size.width, size.height));
	srandom(26);
	for (int i = 0; i < 2600; i++) {
		BOOL light = random() % 2;
		[[UIColor colorWithWhite:light ? 1 : 0 alpha:0.035f + (random() % 40) / 1000.0f] setFill];
		CGFloat x = random() % (int)size.width, y = random() % (int)size.height;
		if (i % 2) CGContextFillRect(c, CGRectMake(x, y, 6 + random() % 30, 0.5f));
		else CGContextFillRect(c, CGRectMake(x, y, 0.5f, 6 + random() % 30));
	}
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

UIImage *WALinen(void) {
	static UIImage *linen;
	if (!linen) linen = SetupImg(@"Linen-568h") ?: SetupImg(@"Linen") ?: DrawnLinen();
	return linen;
}

static UIImageView *LinenView(CGRect frame) {
	UIImageView *bg = [[UIImageView alloc] initWithFrame:frame];
	bg.image = WALinen();
	bg.contentMode = UIViewContentModeTop;
	bg.clipsToBounds = YES;
	bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	return bg;
}

// the embossed "iPhone" of the setup lock screen, but our name
static UIImage *TitleImage(NSString *text, CGFloat width) {
	UIFont *font = [UIFont fontWithName:@"HelveticaNeue-Bold" size:60];
	CGSize size = [text sizeWithFont:font];
	while (size.width > width && font.pointSize > 20) {
		font = [font fontWithSize:font.pointSize - 2];
		size = [text sizeWithFont:font];
	}
	CGSize canvas = CGSizeMake(ceilf(size.width) + 8, ceilf(size.height) + 8);
	UIGraphicsBeginImageContextWithOptions(canvas, NO, 0);
	CGContextRef c = UIGraphicsGetCurrentContext();
	CGPoint at = CGPointMake(4, 3);
	// dark edge below
	CGContextSaveGState(c);
	CGContextSetShadowWithColor(c, CGSizeMake(0, 1.5f), 1.5f, [UIColor colorWithWhite:0 alpha:0.75f].CGColor);
	[[UIColor colorWithWhite:0.55f alpha:1] setFill];
	[text drawAtPoint:at withFont:font];
	CGContextRestoreGState(c);
	// white to grey face. text clip mode mangled the W, so clip to a rendered mask instead
	UIGraphicsBeginImageContextWithOptions(canvas, NO, 0);
	[[UIColor whiteColor] setFill];
	[text drawAtPoint:at withFont:font];
	CGImageRef mask = CGImageRetain(UIGraphicsGetImageFromCurrentImageContext().CGImage);
	UIGraphicsEndImageContext();
	CGContextSaveGState(c);
	CGContextTranslateCTM(c, 0, canvas.height);
	CGContextScaleCTM(c, 1, -1);
	CGContextClipToMask(c, CGRectMake(0, 0, canvas.width, canvas.height), mask);
	CGImageRelease(mask);
	CGFloat colors[] = {0.76f, 0.76f, 0.77f, 1, 0.93f, 0.93f, 0.93f, 1, 1, 1, 1, 1};
	CGFloat stops[] = {0, 0.5f, 1};
	CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
	CGGradientRef g = CGGradientCreateWithColorComponents(space, colors, stops, 3);
	// flipped: bottom of the text first
	CGContextDrawLinearGradient(c, g, CGPointMake(0, canvas.height - at.y - size.height), CGPointMake(0, canvas.height - at.y), 0);
	CGGradientRelease(g);
	CGColorSpaceRelease(space);
	CGContextRestoreGState(c);
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

static UIImage *DrawnRounded(CGSize size, CGFloat radius, UIColor *fill, UIColor *stroke) {
	UIGraphicsBeginImageContextWithOptions(size, NO, 0);
	UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(CGRectMake(0, 0, size.width, size.height), 0.5f, 0.5f)
		cornerRadius:radius];
	[fill setFill];
	[p fill];
	if (stroke) {
		[stroke setStroke];
		[p stroke];
	}
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

// ios 4 has no ThankYou images: white phone outline with text lines, same layout as the 568h one
static UIImage *DrawnThankYouPhone(void) {
	CGSize size = CGSizeMake(120, 225);
	UIGraphicsBeginImageContextWithOptions(size, NO, 0);
	UIColor *white = [UIColor colorWithWhite:0.96f alpha:1];
	UIBezierPath *body = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 2, 116, 221) cornerRadius:18];
	body.lineWidth = 3;
	[white setStroke];
	[body stroke];
	UIBezierPath *screen = [UIBezierPath bezierPathWithRect:CGRectMake(10, 26, 100, 158)];
	screen.lineWidth = 2;
	[screen stroke];
	UIBezierPath *home = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(50, 194, 20, 20)];
	home.lineWidth = 2;
	[home stroke];
	[[UIColor colorWithWhite:0.96f alpha:0.55f] setFill];
	for (NSNumber *y in @[@50, @84, @118, @151]) {
		UIRectFill(CGRectMake(42, y.floatValue, 50, 4));
		UIRectFill(CGRectMake(42, y.floatValue + 7, 30, 4));
	}
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

static UIImage *DrawnCheck(void) {
	CGSize size = CGSizeMake(24, 24);
	UIGraphicsBeginImageContextWithOptions(size, NO, 0);
	[[UIColor colorWithWhite:0.97f alpha:1] setFill];
	[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, 22, 22)] fill];
	UIBezierPath *tick = [UIBezierPath bezierPath];
	[tick moveToPoint:CGPointMake(6.5f, 12.5f)];
	[tick addLineToPoint:CGPointMake(10.5f, 16.5f)];
	[tick addLineToPoint:CGPointMake(18, 7.5f)];
	tick.lineWidth = 2.6f;
	tick.lineCapStyle = kCGLineCapRound;
	tick.lineJoinStyle = kCGLineJoinRound;
	[[UIColor colorWithWhite:0.42f alpha:1] setStroke];
	[tick stroke];
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

static void UseBlackBar(UIViewController *vc) {
	vc.navigationController.navigationBar.barStyle = UIBarStyleBlack;
	vc.navigationController.toolbar.barStyle = UIBarStyleBlack;
}

#pragma mark - Slide to set up

@interface WASetupSlider : UIView
@property (nonatomic, copy) void (^done)(void);
@end

@implementation WASetupSlider {
	UIImageView *_knob;
	UILabel *_label;
	CGFloat _start, _end;
}

- (instancetype)initWithFrame:(CGRect)frame text:(NSString *)text {
	if (!(self = [super initWithFrame:frame])) return nil;
	CGFloat w = frame.size.width, h = frame.size.height;
	UIImageView *bar = [[UIImageView alloc] initWithFrame:self.bounds];
	UIImage *bg = TelephonyImg(@"bottombarbkgnd");
	bar.image = bg ? [bg resizableImageWithCapInsets:UIEdgeInsetsMake(0, 30, 0, 30)] : nil;
	if (!bg) bar.backgroundColor = [UIColor colorWithWhite:0.12f alpha:0.9f];
	bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[self addSubview:bar];

	CGRect trackFrame = CGRectMake(20, floorf((h - 52) / 2), w - 40, 52);
	UIImageView *track = [[UIImageView alloc] initWithFrame:trackFrame];
	UIImage *well = TelephonyImg(@"WellLock");
	track.image = well ? [well resizableImageWithCapInsets:UIEdgeInsetsMake(0, 13, 0, 13)]
		: [DrawnRounded(CGSizeMake(40, 52), 12, [UIColor colorWithWhite:0.05f alpha:1], [UIColor colorWithWhite:0.35f alpha:1])
			resizableImageWithCapInsets:UIEdgeInsetsMake(0, 14, 0, 14)];
	[self addSubview:track];

	_label = [[UILabel alloc] initWithFrame:CGRectMake(CGRectGetMinX(trackFrame) + 64, trackFrame.origin.y, trackFrame.size.width - 70, 52)];
	_label.text = text;
	_label.font = [UIFont fontWithName:@"Helvetica" size:24];
	_label.textColor = [UIColor colorWithWhite:0.55f alpha:1];
	_label.textAlignment = NSTextAlignmentCenter;
	_label.backgroundColor = [UIColor clearColor];
	[self addSubview:_label];
	[self shimmer];

	UIImage *knob = TelephonyImg(@"bottombarknobgray");
	CGSize ks = knob ? knob.size : CGSizeMake(60, 47);
	_start = CGRectGetMinX(trackFrame) + 2;
	_end = CGRectGetMaxX(trackFrame) - 2 - ks.width;
	_knob = [[UIImageView alloc] initWithFrame:CGRectMake(_start, CGRectGetMidY(trackFrame) - ks.height / 2, ks.width, ks.height)];
	_knob.image = knob ?: [self drawnKnob:ks];
	_knob.userInteractionEnabled = YES;
	[_knob addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
	[self addSubview:_knob];
	self.isAccessibilityElement = YES;
	self.accessibilityLabel = [@"Slide to " stringByAppendingString:text];
	return self;
}

- (UIImage *)drawnKnob:(CGSize)size {
	UIImage *base = DrawnRounded(size, 9, [UIColor colorWithWhite:0.9f alpha:1], [UIColor colorWithWhite:0.6f alpha:1]);
	UIGraphicsBeginImageContextWithOptions(size, NO, 0);
	[base drawAtPoint:CGPointZero];
	[[UIColor colorWithWhite:0.45f alpha:1] setFill];
	CGFloat mx = size.width / 2, my = size.height / 2;
	UIBezierPath *arrow = [UIBezierPath bezierPath];
	[arrow moveToPoint:CGPointMake(mx - 14, my - 4)];
	[arrow addLineToPoint:CGPointMake(mx + 2, my - 4)];
	[arrow addLineToPoint:CGPointMake(mx + 2, my - 10)];
	[arrow addLineToPoint:CGPointMake(mx + 14, my)];
	[arrow addLineToPoint:CGPointMake(mx + 2, my + 10)];
	[arrow addLineToPoint:CGPointMake(mx + 2, my + 4)];
	[arrow addLineToPoint:CGPointMake(mx - 14, my + 4)];
	[arrow closePath];
	[arrow fill];
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

// the light running over "set up"
- (void)shimmer {
	CAGradientLayer *mask = [CAGradientLayer layer];
	CGRect b = _label.bounds;
	mask.frame = CGRectMake(-b.size.width, 0, b.size.width * 3, b.size.height);
	mask.startPoint = CGPointMake(0, 0.5f);
	mask.endPoint = CGPointMake(1, 0.5f);
	id dim = (id)[UIColor colorWithWhite:1 alpha:0.38f].CGColor, bright = (id)[UIColor whiteColor].CGColor;
	mask.colors = @[dim, dim, bright, dim, dim];
	mask.locations = @[@0, @0.4f, @0.5f, @0.6f, @1];
	_label.layer.mask = mask;
	// brighter text under the mask, the mask decides how much shows
	_label.textColor = [UIColor whiteColor];
	CABasicAnimation *run = [CABasicAnimation animationWithKeyPath:@"position.x"];
	run.fromValue = @(-b.size.width / 2);
	run.toValue = @(b.size.width * 1.5f);
	run.duration = 2.2;
	run.repeatCount = HUGE_VALF;
	[mask addAnimation:run forKey:@"shimmer"];
}

- (void)pan:(UIPanGestureRecognizer *)pan {
	CGFloat x = MIN(MAX(_start + [pan translationInView:self].x, _start), _end);
	CGRect f = _knob.frame;
	if (pan.state == UIGestureRecognizerStateChanged || pan.state == UIGestureRecognizerStateBegan) {
		f.origin.x = x;
		_knob.frame = f;
		_label.alpha = MAX(0, 1 - (x - _start) / ((_end - _start) * 0.5f));
		return;
	}
	if (pan.state != UIGestureRecognizerStateEnded && pan.state != UIGestureRecognizerStateCancelled) return;
	BOOL through = x >= _end - 6 && pan.state == UIGestureRecognizerStateEnded;
	f.origin.x = through ? _end : _start;
	[UIView animateWithDuration:through ? 0.1 : 0.3 animations:^{
		self->_knob.frame = f;
		self->_label.alpha = through ? 0 : 1;
	} completion:^(BOOL finished) {
		if (through && self.done) self.done();
	}];
}

- (void)reset {
	CGRect f = _knob.frame;
	f.origin.x = _start;
	_knob.frame = f;
	_label.alpha = 1;
	[self shimmer];
}

@end

#pragma mark - Hello

@implementation WAHelloViewController {
	WASetupSlider *_slider;
}

- (void)loadView {
	CGRect frame = [UIScreen mainScreen].applicationFrame;
	UIView *v = [[UIView alloc] initWithFrame:frame];
	v.backgroundColor = [UIColor blackColor];
	[v addSubview:LinenView(v.bounds)];
	CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
	UIImage *title = TitleImage(@"WA Classic", w - 40);
	UIImageView *titleView = [[UIImageView alloc] initWithImage:title];
	titleView.center = CGPointMake(w / 2, floorf((h - 96) / 2) - 6);
	titleView.frame = CGRectIntegral(titleView.frame);
	titleView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
		UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
	[v addSubview:titleView];
	UILabel *small = [[UILabel alloc] initWithFrame:CGRectMake(20, CGRectGetMaxY(titleView.frame) + 4, w - 40, 22)];
	small.text = @"WhatsApp for your classic iPhone";
	small.font = [UIFont fontWithName:@"Helvetica" size:15];
	small.textColor = [UIColor colorWithWhite:0.86f alpha:1];
	small.shadowColor = [UIColor colorWithWhite:0 alpha:0.6f];
	small.shadowOffset = CGSizeMake(0, -1);
	small.backgroundColor = [UIColor clearColor];
	small.textAlignment = NSTextAlignmentCenter;
	[v addSubview:small];

	_slider = [[WASetupSlider alloc] initWithFrame:CGRectMake(0, h - 96, w, 96) text:@"set up"];
	_slider.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
	__weak WAHelloViewController *weak = self;
	_slider.done = ^{ [weak next]; };
	[v addSubview:_slider];
	self.view = v;
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self.navigationController setNavigationBarHidden:YES animated:animated];
	[_slider reset];
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[self.navigationController setNavigationBarHidden:NO animated:animated];
}

- (void)next {
	WALog(@"setup: slid to set up");
	WAHowItWorksViewController *terms = [[WAHowItWorksViewController alloc] init];
	terms.ios5Style = YES;
	terms.finished = self.finished;
	[self.navigationController pushViewController:terms animated:YES];
}

@end

#pragma mark - Diagnostics choice

@implementation WADiagChoiceViewController {
	NSInteger _choice; // -1 none, 0 send, 1 don't
}

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStyleGrouped])) _choice = -1;
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Diagnostics";
	self.tableView.backgroundView = LinenView(self.tableView.bounds);
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Next"
		style:UIBarButtonItemStyleDone target:self action:@selector(next)];
	self.navigationItem.rightBarButtonItem.enabled = NO;
	self.navigationItem.backBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Back"
		style:UIBarButtonItemStyleBordered target:nil action:nil];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	UseBlackBar(self);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return 2;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
	cell.textLabel.text = indexPath.row == 0 ? @"Automatically Send" : @"Don't Send";
	cell.accessoryType = indexPath.row == _choice ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	if (indexPath.row == _choice) cell.textLabel.textColor = WAColor(0x385487);
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	_choice = indexPath.row;
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	[tableView reloadData];
	self.navigationItem.rightBarButtonItem.enabled = YES;
}

static UILabel *LinenLabel(CGRect frame, UIFont *font) {
	UILabel *l = [[UILabel alloc] initWithFrame:frame];
	l.font = font;
	l.textColor = [UIColor whiteColor];
	l.shadowColor = [UIColor colorWithWhite:0 alpha:0.7f];
	l.shadowOffset = CGSizeMake(0, -1);
	l.backgroundColor = [UIColor clearColor];
	l.numberOfLines = 0;
	l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	return l;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
	return 52;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
	UIView *head = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 52)];
	UILabel *l = LinenLabel(CGRectMake(20, 18, head.bounds.size.width - 40, 26), [UIFont boldSystemFontOfSize:19]);
	l.text = @"Diagnostics";
	[head addSubview:l];
	return head;
}

- (NSString *)footerText {
	return @"Help find and fix bugs in WA Classic by automatically sending anonymous diagnostics once a day. Never messages, contacts, numbers or names.";
}

- (CGFloat)footerLabelHeight:(CGFloat)width {
	return ceilf([[self footerText] sizeWithFont:[UIFont systemFontOfSize:15] constrainedToSize:CGSizeMake(width - 60, 400)].height);
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
	return [self footerLabelHeight:tableView.bounds.size.width] + 70;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
	CGFloat w = tableView.bounds.size.width;
	CGFloat lh = [self footerLabelHeight:w];
	UIView *foot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, lh + 70)];
	UILabel *l = LinenLabel(CGRectMake(30, 10, w - 60, lh), [UIFont systemFontOfSize:15]);
	l.text = [self footerText];
	l.textAlignment = NSTextAlignmentCenter;
	[foot addSubview:l];
	UIButton *about = [UIButton buttonWithType:UIButtonTypeCustom];
	about.frame = CGRectMake(30, lh + 22, w - 60, 30);
	about.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	about.titleLabel.font = [UIFont boldSystemFontOfSize:15];
	[about setTitleColor:[UIColor colorWithWhite:0.82f alpha:1] forState:UIControlStateNormal];
	[about setTitleColor:[UIColor whiteColor] forState:UIControlStateHighlighted];
	about.titleLabel.shadowOffset = CGSizeMake(0, -1);
	[about setTitleShadowColor:[UIColor colorWithWhite:0 alpha:0.6f] forState:UIControlStateNormal];
	[about setTitle:@"About Diagnostics and Privacy" forState:UIControlStateNormal];
	[about addTarget:self action:@selector(aboutDiagnostics) forControlEvents:UIControlEventTouchUpInside];
	// underline like the setup link, labels can't on ios 4/5
	CGSize ts = [[about titleForState:UIControlStateNormal] sizeWithFont:about.titleLabel.font];
	UIView *line = [[UIView alloc] initWithFrame:CGRectMake(floorf((about.bounds.size.width - ts.width) / 2), 23, ts.width, 1)];
	line.backgroundColor = [UIColor colorWithWhite:0.82f alpha:1];
	line.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
	line.userInteractionEnabled = NO;
	[about addSubview:line];
	[foot addSubview:about];
	return foot;
}

- (void)aboutDiagnostics {
	[[[UIAlertView alloc] initWithTitle:@"Diagnostics and Privacy"
		message:[WADiagWhat stringByAppendingString:@"\n\nNever messages, contacts, numbers, names, your IP or location. Everything is deleted after 90 days, and turning it off in Settings › Chat Settings › Advanced deletes it right away.\n\nwaclassic.com/legal"]
		delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
}

- (void)next {
	if (_choice < 0) return;
	[[WADiag shared] chosenInSetup:_choice == 0];
	WAConnectViewController *connect = [[WAConnectViewController alloc] init];
	connect.ios5Style = YES;
	connect.finished = self.finished;
	[self.navigationController pushViewController:connect animated:YES];
}

@end

#pragma mark - Thank you

@implementation WAThankYouViewController {
	NSMutableArray *_checks;
}

- (void)loadView {
	CGRect frame = [UIScreen mainScreen].applicationFrame;
	UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, frame.size.height - 44)];
	v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[v addSubview:LinenView(v.bounds)];
	CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
	BOOL tall = h > 420;

	UILabel *head = LinenLabel(CGRectMake(20, tall ? 18 : 10, w - 40, 22), [UIFont boldSystemFontOfSize:17]);
	head.text = @"WA Classic is now set up.";
	head.textAlignment = NSTextAlignmentCenter;
	[v addSubview:head];
	UILabel *sub = LinenLabel(CGRectMake(20, CGRectGetMaxY(head.frame), w - 40, 44), [UIFont systemFontOfSize:17]);
	sub.text = @"You're ready to start chatting the classic way.";
	sub.textAlignment = NSTextAlignmentCenter;
	[v addSubview:sub];

	UIImage *phone = SetupImg(@"ThankYou-568h") ?: SetupImg(@"ThankYou");
	CGSize ps = phone ? phone.size : CGSizeMake(120, 225);
	CGFloat room = h - CGRectGetMaxY(sub.frame) - 90; // button below
	CGFloat scale = MIN(1, room / ps.height);
	UIImageView *pv = [[UIImageView alloc] initWithFrame:CGRectIntegral(CGRectMake((w - ps.width * scale) / 2,
		CGRectGetMaxY(sub.frame) + (room - ps.height * scale) / 2 + 4, ps.width * scale, ps.height * scale))];
	pv.image = phone ?: DrawnThankYouPhone();
	pv.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
	[v addSubview:pv];
	// one check per line on the phone's screen, measured on the 568h image
	UIImage *check = SetupImg(@"ThankYouCheck") ?: DrawnCheck();
	_checks = [NSMutableArray array];
	for (NSNumber *y in @[@54, @88, @122, @155]) {
		UIImageView *cv = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 24 * scale, 24 * scale)];
		cv.image = check;
		cv.center = CGPointMake(26 * scale, y.floatValue * scale);
		cv.alpha = 0;
		[pv addSubview:cv];
		[_checks addObject:cv];
	}

	UIButton *go = [UIButton buttonWithType:UIButtonTypeCustom];
	go.frame = CGRectMake(10, h - 72, w - 20, 50);
	go.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
	[go setBackgroundImage:[DrawnRounded(CGSizeMake(40, 50), 10, [UIColor colorWithWhite:0.97f alpha:1], [UIColor colorWithWhite:0.25f alpha:1])
		resizableImageWithCapInsets:UIEdgeInsetsMake(0, 12, 0, 12)] forState:UIControlStateNormal];
	[go setBackgroundImage:[DrawnRounded(CGSizeMake(40, 50), 10, WAColor(0x3D6FD8), [UIColor colorWithWhite:0.25f alpha:1])
		resizableImageWithCapInsets:UIEdgeInsetsMake(0, 12, 0, 12)] forState:UIControlStateHighlighted];
	[go setTitle:@"Start Using WA Classic" forState:UIControlStateNormal];
	[go setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
	[go setTitleColor:[UIColor whiteColor] forState:UIControlStateHighlighted];
	go.titleLabel.font = [UIFont boldSystemFontOfSize:20];
	[go addTarget:self action:@selector(start) forControlEvents:UIControlEventTouchUpInside];
	[v addSubview:go];
	self.view = v;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Thank You";
	self.navigationItem.hidesBackButton = YES;
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	UseBlackBar(self);
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	NSTimeInterval delay = 0.3;
	for (UIView *check in _checks) {
		[UIView animateWithDuration:0.25 delay:delay options:0 animations:^{ check.alpha = 1; } completion:nil];
		delay += 0.35;
	}
}

- (void)start {
	WALog(@"setup: start using");
	if (self.finished) self.finished();
}

@end
