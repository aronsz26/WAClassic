#import <QuartzCore/QuartzCore.h>
#import "WASetupViewController.h"
#import "WADiag.h"
#import "WAPrefs.h"
#import "WASettingsViewController.h"
#import "WAClient.h"
#import "WAAssets.h"
#import "WAUtil.h"
#import "WAHello.h"

NSString *const WALinkNeededNotification = @"WALinkNeededNotification";

// nib values: Helvetica 17 #4C566C, inputs #324F85
static UILabel *NibLabel(CGRect frame, CGFloat size) {
	UILabel *l = [[UILabel alloc] initWithFrame:frame];
	l.font = [UIFont fontWithName:@"Helvetica" size:size];
	l.textColor = WAColor(0x4C566C);
	l.shadowColor = [UIColor colorWithWhite:1 alpha:0.5];
	l.shadowOffset = CGSizeMake(0, 1);
	l.backgroundColor = [UIColor clearColor];
	l.textAlignment = NSTextAlignmentCenter;
	l.numberOfLines = 0;
	return l;
}

// new installs: white text on linen like the ios 5 setup
static void OnLinen(UILabel *l) {
	l.textColor = [UIColor whiteColor];
	l.shadowColor = [UIColor colorWithWhite:0 alpha:0.7f];
	l.shadowOffset = CGSizeMake(0, -1);
}

static UIImageView *LinenBackground(CGRect frame) {
	UIImageView *bg = [[UIImageView alloc] initWithFrame:frame];
	bg.image = WALinen();
	bg.contentMode = UIViewContentModeTop;
	bg.clipsToBounds = YES;
	bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	return bg;
}

static void BarStyle(UIViewController *vc, BOOL ios5) {
	vc.navigationController.navigationBar.barStyle = ios5 ? UIBarStyleBlack : UIBarStyleDefault;
}

// own drawings for the setup screens, the look of 2.10 only arrives through the bridge later

static void FillGradient(CGContextRef c, CGPoint from, CGPoint to, unsigned top, unsigned bottom) {
	CGFloat colors[] = {((top >> 16) & 255) / 255.0f, ((top >> 8) & 255) / 255.0f, (top & 255) / 255.0f, 1,
		((bottom >> 16) & 255) / 255.0f, ((bottom >> 8) & 255) / 255.0f, (bottom & 255) / 255.0f, 1};
	CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
	CGGradientRef g = CGGradientCreateWithColorComponents(space, colors, NULL, 2);
	CGContextDrawLinearGradient(c, g, from, to, kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
	CGGradientRelease(g);
	CGColorSpaceRelease(space);
}

static void AddRounded(CGContextRef c, CGRect r, CGFloat radius) {
	CGFloat x0 = CGRectGetMinX(r), y0 = CGRectGetMinY(r), x1 = CGRectGetMaxX(r), y1 = CGRectGetMaxY(r);
	CGContextMoveToPoint(c, x0 + radius, y0);
	CGContextAddArcToPoint(c, x1, y0, x1, y1, radius);
	CGContextAddArcToPoint(c, x1, y1, x0, y1, radius);
	CGContextAddArcToPoint(c, x0, y1, x0, y0, radius);
	CGContextAddArcToPoint(c, x0, y0, x1, y0, radius);
	CGContextClosePath(c);
}

static UIImage *DrawnGreenButton(CGSize size) {
	UIGraphicsBeginImageContextWithOptions(size, NO, 0);
	CGContextRef c = UIGraphicsGetCurrentContext();
	CGRect all = CGRectMake(0, 0, size.width, size.height);
	AddRounded(c, CGRectInset(all, 0, 0), 5);
	CGContextSetRGBFillColor(c, 0.03f, 0.35f, 0.08f, 1);
	CGContextFillPath(c);
	CGContextSaveGState(c);
	AddRounded(c, CGRectMake(1, 1, size.width - 2, size.height - 2), 4);
	CGContextClip(c);
	FillGradient(c, CGPointMake(0, 1), CGPointMake(0, size.height - 1), 0x25D63D, 0x0FA817);
	CGContextSetRGBFillColor(c, 1, 1, 1, 0.3f);
	CGContextFillRect(c, CGRectMake(0, 1, size.width, 1));
	CGContextRestoreGState(c);
	UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return image;
}

// white box with a green ribbon on the corner, same size as BoxShadow
static UIImage *DrawnBox(void) {
	UIGraphicsBeginImageContextWithOptions(CGSizeMake(320, 250), NO, 0);
	CGContextRef c = UIGraphicsGetCurrentContext();
	CGRect body = CGRectMake(54, 6, 212, 212);

	CGContextSaveGState(c);
	CGContextSetShadowWithColor(c, CGSizeMake(0, 9), 20, [UIColor colorWithWhite:0 alpha:0.5f].CGColor);
	CGContextSetRGBFillColor(c, 0.9f, 0.9f, 0.9f, 1);
	CGContextFillRect(c, body);
	CGContextRestoreGState(c);

	CGContextSaveGState(c);
	CGContextClipToRect(c, body);
	FillGradient(c, CGPointMake(0, 6), CGPointMake(0, 218), 0xFBFBFB, 0xE7E7E7);
	CGContextSetRGBFillColor(c, 0, 0, 0, 0.05f);
	CGContextFillRect(c, CGRectMake(54, 17, 212, 1));
	CGContextSetRGBFillColor(c, 1, 1, 1, 0.9f);
	CGContextFillRect(c, CGRectMake(54, 6, 212, 1));
	CGContextFillRect(c, CGRectMake(54, 18, 212, 1));
	CGContextSetRGBFillColor(c, 0, 0, 0, 0.18f);
	CGContextFillRect(c, CGRectMake(54, 217, 212, 1));
	CGContextRestoreGState(c);

	// ribbon, wider than the box corner so it wraps around
	CGMutablePathRef ribbon = CGPathCreateMutable();
	CGPathMoveToPoint(ribbon, NULL, 103, 6);
	CGPathAddLineToPoint(ribbon, NULL, 131, 6);
	CGPathAddLineToPoint(ribbon, NULL, 54, 85);
	CGPathAddLineToPoint(ribbon, NULL, 52, 85);
	CGPathAddLineToPoint(ribbon, NULL, 52, 57);
	CGPathCloseSubpath(ribbon);
	CGContextSaveGState(c);
	CGContextSetShadowWithColor(c, CGSizeMake(1, 2), 3, [UIColor colorWithWhite:0 alpha:0.35f].CGColor);
	CGContextAddPath(c, ribbon);
	CGContextSetRGBFillColor(c, 0.1f, 0.6f, 0.13f, 1);
	CGContextFillPath(c);
	CGContextRestoreGState(c);
	CGContextSaveGState(c);
	CGContextAddPath(c, ribbon);
	CGContextClip(c);
	FillGradient(c, CGPointMake(74, 28), CGPointMake(110, 64), 0x34C53A, 0x139A1C);
	CGContextSetRGBStrokeColor(c, 1, 1, 1, 0.28f);
	CGContextSetLineWidth(c, 1);
	CGContextMoveToPoint(c, 108, 6); CGContextAddLineToPoint(c, 52, 63);
	CGContextMoveToPoint(c, 126, 6); CGContextAddLineToPoint(c, 52, 80);
	CGContextStrokePath(c);
	CGContextRestoreGState(c);
	CGPathRelease(ribbon);

	UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return image;
}

// teal with a light middle and a faint pattern of simple shapes
static UIImage *DrawnWelcomeBackground(CGSize size) {
	UIGraphicsBeginImageContextWithOptions(size, YES, 0);
	CGContextRef c = UIGraphicsGetCurrentContext();
	const CGFloat colors[] = {0.17f, 0.54f, 0.56f, 1, 0.09f, 0.29f, 0.32f, 1};
	CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
	CGGradientRef g = CGGradientCreateWithColorComponents(space, colors, NULL, 2);
	CGPoint middle = CGPointMake(size.width / 2, size.height * 0.48f);
	CGContextDrawRadialGradient(c, g, middle, 0, middle, MAX(size.width, size.height) * 0.62f, kCGGradientDrawsAfterEndLocation);
	CGGradientRelease(g);
	CGColorSpaceRelease(space);

	CGContextSetRGBStrokeColor(c, 0.65f, 0.95f, 0.95f, 0.13f);
	CGContextSetLineWidth(c, 1.2f);
	CGContextSetLineJoin(c, kCGLineJoinRound);
	unsigned seed = 2012;
	for (CGFloat y = 12; y < size.height; y += 42) {
		for (CGFloat x = 12; x < size.width; x += 42) {
			seed = seed * 1103515245 + 12345;
			unsigned r = seed >> 16;
			CGContextSaveGState(c);
			CGContextTranslateCTM(c, x + (r % 15), y + ((r >> 4) % 15));
			CGContextRotateCTM(c, ((r >> 8) % 60 - 30) * (CGFloat)M_PI / 180);
			switch ((r >> 3) % 4) {
				case 0: // bubble
					AddRounded(c, CGRectMake(-9, -7, 18, 12), 4);
					CGContextMoveToPoint(c, -4, 5);
					CGContextAddLineToPoint(c, -6, 10);
					CGContextAddLineToPoint(c, 1, 5);
					break;
				case 1:
					CGContextAddEllipseInRect(c, CGRectMake(-7, -7, 14, 14));
					CGContextAddEllipseInRect(c, CGRectMake(-2, -2, 4, 4));
					break;
				case 2: // star
					for (int i = 0; i < 10; i++) {
						CGFloat a = i * (CGFloat)M_PI / 5 - (CGFloat)M_PI_2, l = i % 2 ? 3.5f : 8;
						CGPoint p = CGPointMake(cosf(a) * l, sinf(a) * l);
						if (i) CGContextAddLineToPoint(c, p.x, p.y);
						else CGContextMoveToPoint(c, p.x, p.y);
					}
					CGContextClosePath(c);
					break;
				default: // phone
					AddRounded(c, CGRectMake(-5, -9, 10, 18), 2);
					CGContextMoveToPoint(c, -2, 6);
					CGContextAddLineToPoint(c, 2, 6);
					break;
			}
			CGContextStrokePath(c);
			CGContextRestoreGState(c);
		}
	}
	UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return image;
}

static UIButton *GreenButton(NSString *title, CGRect frame) {
	UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
	b.frame = frame;
	b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
	[b setBackgroundImage:WAImg(@"PayNowBtn") ?: DrawnGreenButton(frame.size) forState:UIControlStateNormal];
	[b setTitle:title forState:UIControlStateNormal];
	b.titleLabel.font = [UIFont fontWithName:@"HelveticaNeue-Bold" size:19];
	[b setTitleShadowColor:[UIColor colorWithWhite:0 alpha:0.35] forState:UIControlStateNormal];
	b.titleLabel.shadowOffset = CGSizeMake(0, -1);
	return b;
}

#pragma mark - Loading the chats after linking

static const NSTimeInterval kLoadingMinimum = 3, kLoadingLimit = 60;

static void AddChatBubble(CGContextRef c, CGRect r, BOOL tailRight) {
	CGFloat x0 = CGRectGetMinX(r), x1 = CGRectGetMaxX(r), y1 = CGRectGetMaxY(r);
	AddRounded(c, r, 14);
	if (tailRight) {
		CGContextMoveToPoint(c, x1 - 4, y1 - 20);
		CGContextAddLineToPoint(c, x1 + 9, y1 + 2);
		CGContextAddLineToPoint(c, x1 - 20, y1);
	} else {
		CGContextMoveToPoint(c, x0 + 20, y1);
		CGContextAddLineToPoint(c, x0 - 9, y1 + 2);
		CGContextAddLineToPoint(c, x0 + 4, y1 - 20);
	}
	CGContextClosePath(c);
}

static void DrawChatBubble(CGContextRef c, CGRect r, BOOL tailRight, unsigned top, unsigned bottom, UIColor *lines) {
	CGContextSaveGState(c);
	CGContextSetShadowWithColor(c, CGSizeMake(0, 2), 5, [UIColor colorWithWhite:0 alpha:0.35f].CGColor);
	AddChatBubble(c, r, tailRight);
	[[UIColor colorWithWhite:0.5f alpha:1] setFill];
	CGContextFillPath(c);
	CGContextRestoreGState(c);
	CGContextSaveGState(c);
	AddChatBubble(c, r, tailRight);
	CGContextClip(c);
	FillGradient(c, CGPointMake(0, CGRectGetMinY(r)), CGPointMake(0, CGRectGetMaxY(r)), top, bottom);
	[[UIColor colorWithWhite:1 alpha:0.28f] setFill];
	AddRounded(c, CGRectMake(CGRectGetMinX(r) + 2, CGRectGetMinY(r) + 1, r.size.width - 4, r.size.height * 0.45f), 12);
	CGContextFillPath(c);
	CGContextRestoreGState(c);
	[lines setFill];
	AddRounded(c, CGRectMake(CGRectGetMinX(r) + 16, CGRectGetMinY(r) + 18, r.size.width - 34, 7), 3.5f);
	AddRounded(c, CGRectMake(CGRectGetMinX(r) + 16, CGRectGetMinY(r) + 34, r.size.width - 58, 7), 3.5f);
	CGContextFillPath(c);
}

static UIImage *DrawnChatsImage(void) {
	UIGraphicsBeginImageContextWithOptions(CGSizeMake(200, 135), NO, 0);
	CGContextRef c = UIGraphicsGetCurrentContext();
	DrawChatBubble(c, CGRectMake(16, 8, 128, 62), NO, 0xFFFFFF, 0xE3E6EA, WAColor(0xBFC5CE));
	DrawChatBubble(c, CGRectMake(56, 60, 128, 62), YES, 0x8EDD6A, 0x4FB52F, [UIColor colorWithWhite:1 alpha:0.85f]);
	UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return image;
}

@implementation WALoadingChatsViewController {
	NSTimer *_timer;
	NSDate *_started;
	NSInteger _lastCount;
	BOOL _done;
}

- (void)loadView {
	CGRect frame = [UIScreen mainScreen].applicationFrame;
	UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, frame.size.height - 44)];
	v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	self.view = v;
	if (self.ios5Style) [v addSubview:LinenBackground(v.bounds)];
	else {
		// empty grouped table for the pinstripes (pattern color went black)
		UITableView *table = [[UITableView alloc] initWithFrame:v.bounds style:UITableViewStyleGrouped];
		table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		table.scrollEnabled = NO;
		table.allowsSelection = NO;
		[v addSubview:table];
	}

	CGFloat w = v.bounds.size.width, top = v.bounds.size.height > 460 ? 52 : 18;
	UIView *group = [[UIView alloc] initWithFrame:CGRectMake(0, top, w, 320)];
	group.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[v addSubview:group];
	UIImageView *art = [[UIImageView alloc] initWithImage:DrawnChatsImage()];
	art.center = CGPointMake(floorf(w / 2), 70);
	art.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
	[group addSubview:art];
	UILabel *title = NibLabel(CGRectMake(10, 152, w - 20, 48), 19);
	title.text = @"Loading Chats and Conversations";
	title.font = [UIFont fontWithName:@"Helvetica-Bold" size:19];
	title.shadowColor = [UIColor whiteColor];
	title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	if (self.ios5Style) OnLinen(title);
	[group addSubview:title];
	UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:
		self.ios5Style ? UIActivityIndicatorViewStyleWhite : UIActivityIndicatorViewStyleGray];
	spinner.center = CGPointMake(floorf(w / 2), 222);
	spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
	[spinner startAnimating];
	[group addSubview:spinner];
	UILabel *note = NibLabel(CGRectMake(20, 244, w - 40, 60), 15);
	note.text = @"This can take a moment. Keep WhatsApp on your phone connected to the internet.";
	note.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	if (self.ios5Style) OnLinen(note);
	[group addSubview:note];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Loading";
	self.navigationItem.hidesBackButton = YES;
	_started = [NSDate date];
	_lastCount = -1;
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	BarStyle(self, self.ios5Style);
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	[self poll];
	if (!_timer) _timer = [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(poll) userInfo:nil repeats:YES];
}

- (void)poll {
	NSTimeInterval shown = -[_started timeIntervalSinceNow];
	if (shown >= kLoadingLimit) {
		WALog(@"setup: no chats after %d s, going on", (int)kLoadingLimit);
		[self finish];
		return;
	}
	[[WAClient shared] get:@"/api/chats" params:nil completion:^(id json, NSError *error) {
		if (self->_done || ![json isKindOfClass:[NSDictionary class]]) return;
		NSArray *chats = json[@"chats"];
		NSInteger count = [chats isKindOfClass:[NSArray class]] ? (NSInteger)chats.count : 0;
		// the list is there once it stops growing
		BOOL settled = count > 0 && count == self->_lastCount;
		self->_lastCount = count;
		if (settled && -[self->_started timeIntervalSinceNow] >= kLoadingMinimum) [self finish];
	}];
}

- (void)finish {
	if (_done) return;
	_done = YES;
	[_timer invalidate];
	_timer = nil;
	WALog(@"setup: chats loaded");
	if (self.finished) self.finished();
}

@end

#pragma mark - QR code (PhoneInputView.nib)

@implementation WASetupViewController {
	UIView *_content;
	UILabel *_header, *_footer;
	UIImageView *_box, *_qr;
	UIActivityIndicatorView *_spinner;
	NSTimer *_timer;
	BOOL _loading, _linked;
}

- (void)loadView {
	// empty grouped table for the pinstripes (pattern color went black)
	UITableView *table = [[UITableView alloc] initWithFrame:[UIScreen mainScreen].applicationFrame style:UITableViewStyleGrouped];
	table.allowsSelection = NO;
	self.view = table;
	if (self.ios5Style) table.backgroundView = LinenBackground(table.bounds);
	_content = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 400)];

	// header text
	_header = NibLabel(CGRectMake(10, 12, 300, 42), 17);
	_header.text = @"To use WhatsApp on this iPhone, open WhatsApp on your phone, tap Settings > Linked Devices > Link a Device and scan this code.";
	CGSize fit = [_header.text sizeWithFont:_header.font constrainedToSize:CGSizeMake(300, 200) lineBreakMode:NSLineBreakByWordWrapping];
	_header.frame = CGRectMake(10, 12, 300, ceilf(fit.height));
	_header.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
	if (self.ios5Style) OnLinen(_header);
	[_content addSubview:_header];

	// qr box instead of the phone fields (256pt = 512px)
	CGFloat top = CGRectGetMaxY(_header.frame) + 14;
	_box = [[UIImageView alloc] initWithFrame:CGRectMake(22, top, 276, 276)];
	UIImage *bg = self.ios5Style ? nil : WAStretch(@"TextFieldBg", 12, 12, 12, 12);
	_box.image = bg;
	if (!bg) {
		_box.backgroundColor = [UIColor whiteColor];
		_box.layer.cornerRadius = 10;
		_box.layer.borderWidth = 1;
		_box.layer.borderColor = [UIColor colorWithWhite:0.6 alpha:1].CGColor;
	}
	_box.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
	[_content addSubview:_box];
	_qr = [[UIImageView alloc] initWithFrame:CGRectInset(_box.bounds, 10, 10)];
	_qr.layer.magnificationFilter = kCAFilterNearest; // crisp on the 3gs too
	_qr.layer.minificationFilter = kCAFilterNearest;
	[_box addSubview:_qr];
	_spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
	_spinner.center = CGPointMake(138, 138);
	[_box addSubview:_spinner];

	// footer
	_footer = NibLabel(CGRectMake(10, CGRectGetMaxY(_box.frame) + 10, 300, 40), 15);
	_footer.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
	if (self.ios5Style) OnLinen(_footer);
	[_content addSubview:_footer];
	_content.frame = CGRectMake(0, 0, 320, CGRectGetMaxY(_footer.frame) + 10);
	table.tableHeaderView = _content;
	[self showState:@"Waiting for a code from WhatsApp…" qr:nil];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Link Your Phone";
	// no bridge, no code
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Network"
		style:UIBarButtonItemStyleBordered target:self action:@selector(network)];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	BarStyle(self, self.ios5Style);
	if (_linked) return;
	[self poll];
	_timer = [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(poll) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[_timer invalidate];
	_timer = nil;
}

- (void)network {
	[self.navigationController pushViewController:[[WASettingsViewController alloc] init] animated:YES];
}

- (void)showState:(NSString *)text qr:(UIImage *)qr {
	_footer.text = text;
	if (qr) _qr.image = qr;
	_qr.hidden = qr == nil;
	if (qr) [_spinner stopAnimating];
	else [_spinner startAnimating];
}

- (void)poll {
	if (_loading || _linked) return;
	if (![WAClient shared].configured) {
		[self showState:@"Tap Network to set up your WA Classic bridge." qr:nil];
		return;
	}
	_loading = YES;
	NSMutableURLRequest *req = [[WAClient shared] requestFor:@"/api/pair/qr" params:nil];
	req.timeoutInterval = 10;
	[[WAClient shared] load:req completion:^(NSData *data, NSInteger status, NSError *error) {
		self->_loading = NO;
		if (self->_linked) return;
		if (status == 200 && data.length) {
			UIImage *img = [UIImage imageWithData:data scale:2];
			if (img) [self showState:@"Point your phone at this code.\nIt renews itself every few seconds." qr:img];
		} else if (status == 410) {
			[self linkedNow];
		} else if (status == 503) {
			[self showState:@"Waiting for a code from WhatsApp…" qr:nil];
		} else {
			WALog(@"setup: qr status %ld %@", (long)status, error.localizedDescription ?: @"");
			[self showState:error ? @"Connecting..." : [NSString stringWithFormat:@"There was a problem with the service. Code = %ld.", (long)status] qr:nil];
			if (error) [[WAClient shared] chooseServer:nil];
		}
	}];
}

- (void)linkedNow {
	_linked = YES;
	[_timer invalidate];
	_timer = nil;
	WALog(@"setup: linked");
	[self showState:@"Connected" qr:nil];
	// start counter at the bridge's so history sync doesn't notify
	[[WAClient shared] get:@"/api/status" params:nil completion:^(id json, NSError *error) {
		if ([json isKindOfClass:[NSDictionary class]]) [[WAClient shared] noteUpd:[json[@"upd"] longLongValue]];
		// wait for the history, then the chats
		WALoadingChatsViewController *loading = [[WALoadingChatsViewController alloc] init];
		loading.ios5Style = self.ios5Style;
		loading.finished = self.finished;
		[self.navigationController pushViewController:loading animated:YES];
	}];
}

@end

#pragma mark - Connect to the bridge (in PhoneInputView.nib's style)

@implementation WAConnectViewController {
	UITextField *_address, *_code;
	UILabel *_footer;
	BOOL _busy;
}

- (instancetype)init {
	return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Your Bridge";
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Next"
		style:UIBarButtonItemStyleDone target:self action:@selector(next)];
	UIView *head = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 80)];
	UILabel *text = NibLabel(CGRectMake(10, 12, 300, 60), 17);
	text.text = @"Enter the address and the code from your WA Classic bridge page.";
	text.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
	[head addSubview:text];
	self.tableView.tableHeaderView = head;
	if (self.ios5Style) {
		self.tableView.backgroundView = LinenBackground(self.tableView.bounds);
		OnLinen(text);
	}
	UIView *foot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 90)];
	_footer = NibLabel(CGRectMake(10, 6, 300, 80), 15);
	_footer.text = @"Both are shown on your bridge page in the browser.";
	_footer.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
	[foot addSubview:_footer];
	self.tableView.tableFooterView = foot;
	if (self.ios5Style) OnLinen(_footer);
	_address = [self field:@"192.168.1.20" keyboard:UIKeyboardTypeURL];
	_address.text = [WAClient shared].homeURL;
	_code = [self field:@"123456" keyboard:UIKeyboardTypeNumberPad];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	BarStyle(self, self.ios5Style);
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	[(_address.text.length ? _code : _address) becomeFirstResponder];
}

- (UITextField *)field:(NSString *)placeholder keyboard:(UIKeyboardType)keyboard {
	UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 180, 24)];
	f.placeholder = placeholder;
	f.keyboardType = keyboard;
	f.autocorrectionType = UITextAutocorrectionTypeNo;
	f.autocapitalizationType = UITextAutocapitalizationTypeNone;
	f.clearButtonMode = UITextFieldViewModeWhileEditing;
	f.font = [UIFont fontWithName:@"Helvetica" size:17];
	f.textColor = WAColor(0x324F85);
	f.delegate = self;
	return f;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
	if (textField == _address) [_code becomeFirstResponder];
	else [self next];
	return YES;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return 2;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
	cell.textLabel.text = indexPath.row == 0 ? @"Address" : @"Code";
	cell.accessoryView = indexPath.row == 0 ? _address : _code;
	return cell;
}

- (void)next {
	if (_busy) return;
	_busy = YES;
	[self.view endEditing:YES];
	UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
	[spin startAnimating];
	UIBarButtonItem *nextItem = self.navigationItem.rightBarButtonItem;
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:spin];
	[[WAClient shared] setupWithAddress:_address.text code:_code.text completion:^(NSError *error) {
		self->_busy = NO;
		self.navigationItem.rightBarButtonItem = nextItem;
		if (error) {
			[[[UIAlertView alloc] initWithTitle:nil message:error.localizedDescription delegate:nil
				cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
			return;
		}
		WASetupViewController *qr = [[WASetupViewController alloc] init];
		qr.ios5Style = self.ios5Style;
		qr.finished = self.finished;
		[self.navigationController pushViewController:qr animated:YES];
	}];
}

@end

#pragma mark - How it works (scroll box like terms, button stays)

static UIFont *HowFont(void) {
	return [UIFont fontWithName:@"Helvetica" size:15];
}

@interface WAHowItWorksViewController () <UIScrollViewDelegate, UIAlertViewDelegate>
@end

@implementation WAHowItWorksViewController {
	UIScrollView *_scroll;
	UISwitch *_diag;
	UIButton *_go;
	UIView *_track, *_thumb;
}

- (void)loadView {
	CGRect frame = [UIScreen mainScreen].applicationFrame;
	// ios 5 style has a toolbar below instead of the green button
	UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, frame.size.height - (self.ios5Style ? 88 : 44))];
	v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	self.view = v;
	if (self.ios5Style) {
		UIImageView *linen = [[UIImageView alloc] initWithFrame:v.bounds];
		linen.image = WALinen();
		linen.contentMode = UIViewContentModeTop;
		linen.clipsToBounds = YES;
		linen.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[v addSubview:linen];
	} else {
		// empty grouped table for the pinstripes (pattern color went black)
		UITableView *table = [[UITableView alloc] initWithFrame:v.bounds style:UITableViewStyleGrouped];
		table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		table.scrollEnabled = NO;
		table.allowsSelection = NO;
		[v addSubview:table];
	}

	CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
	UIView *box = [[UIView alloc] initWithFrame:CGRectMake(10, 10, w - 20, h - (self.ios5Style ? 20 : 75))];
	box.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	box.backgroundColor = self.ios5Style ? [UIColor whiteColor] : [UIColor colorWithWhite:0.97f alpha:1];
	box.layer.cornerRadius = 10;
	box.layer.borderWidth = 1;
	box.layer.borderColor = [UIColor colorWithWhite:0.67f alpha:1].CGColor;
	box.clipsToBounds = YES;
	[v addSubview:box];
	_scroll = [[UIScrollView alloc] initWithFrame:box.bounds];
	_scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_scroll.delegate = self;
	_scroll.showsVerticalScrollIndicator = NO;
	[box addSubview:_scroll];
	_track = [[UIView alloc] initWithFrame:CGRectMake(box.bounds.size.width - 11, 8, 6, box.bounds.size.height - 16)];
	_track.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleHeight;
	_track.backgroundColor = [UIColor colorWithWhite:0 alpha:0.07f];
	_track.layer.cornerRadius = 3;
	[box addSubview:_track];
	_thumb = [[UIView alloc] initWithFrame:CGRectZero];
	_thumb.backgroundColor = [UIColor colorWithWhite:0 alpha:0.38f];
	_thumb.layer.cornerRadius = 3;
	[box addSubview:_thumb];
	[self fillScroll];
	if (self.ios5Style) return;

	UIButton *go = GreenButton(@"Agree and Continue", CGRectMake(floorf((w - 258) / 2), h - 53, 258, 41));
	go.autoresizingMask |= UIViewAutoresizingFlexibleTopMargin;
	[go addTarget:self action:@selector(next) forControlEvents:UIControlEventTouchUpInside];
	// read to the end first
	go.enabled = NO;
	go.alpha = 0.5f;
	_go = go;
	[v addSubview:go];
}

- (void)scrollViewDidScroll:(UIScrollView *)scroll {
	[self updateBar];
	[self checkRead];
}

- (void)checkRead {
	if (self.ios5Style) {
		UIBarButtonItem *agree = self.toolbarItems.lastObject;
		if (_scroll.contentOffset.y + _scroll.bounds.size.height >= _scroll.contentSize.height - 12) agree.enabled = YES;
		return;
	}
	if (_go.enabled) return;
	if (_scroll.contentOffset.y + _scroll.bounds.size.height >= _scroll.contentSize.height - 12) {
		_go.enabled = YES;
		[UIView animateWithDuration:0.2 animations:^{ self->_go.alpha = 1; }];
	}
}

// terms style: numbered points, read to the end before Agree and Continue works
- (void)fillScroll {
	NSArray *points = @[
		@[@"About WA Classic", @"WA Classic is unofficial. It isn't made by or connected to WhatsApp or Meta."],
		@[@"Your bridge", @"WA Classic runs through your own bridge, a small program on your computer. It is linked to WhatsApp like WhatsApp Web. There is no WA Classic server: your messages go from WhatsApp to your bridge and then to this iPhone.",
			@"The bridge stores your messages unencrypted, so only run it on a computer you trust."],
		@[@"Staying connected", @"Keep the bridge running. While it's off or asleep, nothing arrives.",
			@"Your phone has to come online about every two weeks, or WhatsApp unlinks the bridge."],
		@[@"Your account", @"Using WA Classic may break WhatsApp's terms of service, and your account could be banned. If you can't risk that, don't link your main account."],
		@[@"Updates", @"WA Classic asks update.waclassic.com every few hours if there's a new version. That request contains nothing about you."],
	];
	CGFloat width = _scroll.bounds.size.width, left = 14, right = 22, y = 14;
	CGFloat textWidth = width - left - right;
	y = [self addText:self.ios5Style ? @"Please read these points to the end. Agree works once you've scrolled down."
		: @"Please read these points to the end. Agree and Continue works once you've scrolled down."
		font:[UIFont fontWithName:@"Helvetica-Oblique" size:14] color:WAColor(0x6D6D72) y:y width:textWidth left:left] + 16;
	NSUInteger number = 1;
	for (NSArray *point in points) {
		y = [self addHeading:[NSString stringWithFormat:@"%lu. %@", (unsigned long)number++, point[0]] y:y width:textWidth left:left];
		for (NSString *text in [point subarrayWithRange:NSMakeRange(1, point.count - 1)]) {
			y = [self addText:text font:HowFont() color:[UIColor blackColor] y:y width:textWidth left:left] + 8;
		}
		y += 8;
	}
	if (!self.ios5Style) y = [self addDiagnosticsAt:y number:number++ width:textWidth left:left];
	y = [self addHeading:[NSString stringWithFormat:@"%lu. Help", (unsigned long)number] y:y width:textWidth left:left];
	y = [self addText:@"Set up your bridge first. The guide is on guide.waclassic.com, open it on your computer. Stuck? Ask on our Discord: discord.gg/HaTErjRdbk"
		font:HowFont() color:[UIColor blackColor] y:y width:textWidth left:left] + 16;
	y = [self addText:self.ios5Style ? @"By tapping Agree you accept points 1 to 5. Privacy policy: waclassic.com/legal"
		: @"By tapping Agree and Continue you accept points 1 to 5. Diagnostics stay off unless you turn them on. Privacy policy: waclassic.com/legal"
		font:[UIFont fontWithName:@"Helvetica" size:13] color:WAColor(0x6D6D72) y:y width:textWidth left:left] + 14;
	_scroll.contentSize = CGSizeMake(width, y);
	[self updateBar];
}

- (CGFloat)addHeading:(NSString *)text y:(CGFloat)y width:(CGFloat)width left:(CGFloat)left {
	UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(left, y, width, 20)];
	title.text = text;
	title.font = [UIFont fontWithName:@"Helvetica-Bold" size:15];
	title.textColor = WAColor(0x4C566C);
	title.backgroundColor = [UIColor clearColor];
	[_scroll addSubview:title];
	return y + 25;
}

- (CGFloat)addText:(NSString *)text font:(UIFont *)font color:(UIColor *)color y:(CGFloat)y width:(CGFloat)width left:(CGFloat)left {
	CGSize fit = [text sizeWithFont:font constrainedToSize:CGSizeMake(width, 600) lineBreakMode:NSLineBreakByWordWrapping];
	UILabel *row = [[UILabel alloc] initWithFrame:CGRectMake(left, y, width, ceilf(fit.height))];
	row.text = text;
	row.font = font;
	row.textColor = color;
	row.numberOfLines = 0;
	row.backgroundColor = [UIColor clearColor];
	[_scroll addSubview:row];
	return y + ceilf(fit.height);
}

// optional, off unless switched on. agreeing below doesn't turn it on
- (CGFloat)addDiagnosticsAt:(CGFloat)y number:(NSUInteger)number width:(CGFloat)width left:(CGFloat)left {
	y = [self addHeading:[NSString stringWithFormat:@"%lu. Diagnostics (optional)", (unsigned long)number] y:y width:width left:left];
	y = [self addText:@"Helps find bugs faster. Once a day: your iPhone model, iOS and app version, bridge version and system, language, crash reports and error codes. Never messages, contacts, numbers or names. You can change it later in Settings › Chat Settings › Advanced."
		font:HowFont() color:[UIColor blackColor] y:y width:width left:left] + 10;
	_diag = [[UISwitch alloc] init];
	_diag.on = WAPrefBool(WAPrefDiagnostics);
	CGRect sf = _diag.frame;
	sf.origin = CGPointMake(left + width - sf.size.width, y);
	_diag.frame = sf;
	[_scroll addSubview:_diag];
	UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(left, y, sf.origin.x - left - 8, sf.size.height)];
	name.text = @"Send Diagnostics";
	name.font = [UIFont boldSystemFontOfSize:15];
	name.backgroundColor = [UIColor clearColor];
	[_scroll addSubview:name];
	return y + sf.size.height + 18;
}

// always visible scroll bar, ios only flashes its own
- (void)updateBar {
	CGFloat content = _scroll.contentSize.height, visible = _scroll.bounds.size.height;
	BOOL fits = content <= visible + 1;
	_track.hidden = _thumb.hidden = fits;
	if (fits) return;
	CGRect track = _track.frame;
	CGFloat h = MAX(34, track.size.height * visible / content);
	CGFloat progress = MIN(MAX(_scroll.contentOffset.y / (content - visible), 0), 1);
	_thumb.frame = CGRectMake(track.origin.x, track.origin.y + (track.size.height - h) * progress, track.size.width, h);
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = self.ios5Style ? @"Terms and Conditions" : @"Terms";
	self.navigationItem.backBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Back"
		style:UIBarButtonItemStyleBordered target:nil action:nil];
	if (self.ios5Style) {
		self.navigationItem.hidesBackButton = YES;
		UIBarButtonItem *no = [[UIBarButtonItem alloc] initWithTitle:@"Disagree" style:UIBarButtonItemStyleBordered
			target:self action:@selector(disagree)];
		UIBarButtonItem *yes = [[UIBarButtonItem alloc] initWithTitle:@"Agree" style:UIBarButtonItemStyleDone
			target:self action:@selector(agree)];
		yes.enabled = NO;
		UIBarButtonItem *space = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
		self.toolbarItems = @[no, space, yes];
	}
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	if (!self.ios5Style) return;
	self.navigationController.navigationBar.barStyle = UIBarStyleBlack;
	self.navigationController.toolbar.barStyle = UIBarStyleBlack;
	[self.navigationController setToolbarHidden:NO animated:animated];
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	if (self.ios5Style) [self.navigationController setToolbarHidden:YES animated:animated];
}

// like the setup: Disagree goes back to the start, Agree asks once more
- (void)disagree {
	[[[UIAlertView alloc] initWithTitle:nil message:@"You have to agree to the terms to use WA Classic."
		delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
}

- (void)agree {
	UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Terms and Conditions"
		message:@"I agree to the WA Classic terms and conditions." delegate:self cancelButtonTitle:@"Disagree" otherButtonTitles:@"Agree", nil];
	[alert show];
}

- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index {
	if (index == alert.cancelButtonIndex) return;
	WALog(@"setup: terms agreed");
	WADiagChoiceViewController *diag = [[WADiagChoiceViewController alloc] init];
	diag.finished = self.finished;
	[self.navigationController pushViewController:diag animated:YES];
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	[self updateBar];
	[self checkRead]; // fits without scrolling on a big screen
}

- (void)next {
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	[d setBool:YES forKey:@"diagAsked"]; // asked here, no popup later
	if (_diag.on && ![d boolForKey:WAPrefDiagnostics]) [d setDouble:[[NSDate date] timeIntervalSince1970] forKey:@"diagCrashSeen"];
	[d setBool:_diag.on forKey:WAPrefDiagnostics];
	// new install: bridge first, then qr
	if (![WAClient shared].configured) {
		WAConnectViewController *connect = [[WAConnectViewController alloc] init];
		connect.finished = self.finished;
		[self.navigationController pushViewController:connect animated:YES];
		return;
	}
	WASetupViewController *qr = [[WASetupViewController alloc] init];
	qr.finished = self.finished;
	[self.navigationController pushViewController:qr animated:YES];
}

@end

#pragma mark - Welcome (PaymentEduViewController)

@implementation WAWelcomeViewController

- (void)loadView {
	UIView *v = [[UIView alloc] initWithFrame:[UIScreen mainScreen].applicationFrame];
	v.backgroundColor = WAColor(0x1F5658);
	// only @2x exists
	NSData *wp = [NSData dataWithContentsOfFile:WAAssetPath(@"PaymentWP@2x.jpg")];
	UIImageView *bg = [[UIImageView alloc] initWithFrame:v.bounds];
	bg.image = wp ? [UIImage imageWithData:wp scale:2] : DrawnWelcomeBackground(v.bounds.size);
	bg.contentMode = UIViewContentModeScaleAspectFill;
	bg.clipsToBounds = YES;
	bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[v addSubview:bg];
	self.view = v;

	// white box with ribbon
	CGFloat top = v.bounds.size.height > 460 ? 24 : 6;
	UIImageView *box = [[UIImageView alloc] initWithFrame:CGRectMake(0, top, 320, 250)];
	box.image = WAImg(@"BoxShadow") ?: DrawnBox();
	box.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
	[v addSubview:box];
	// welcome text
	UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(68, 40, 184, 64)];
	title.text = @"Welcome to\nWA Classic";
	title.font = [UIFont fontWithName:@"HelveticaNeue-Light" size:24];
	title.textColor = WAColor(0x3C3C3C);
	title.shadowColor = [UIColor whiteColor];
	title.shadowOffset = CGSizeMake(0, 1);
	title.backgroundColor = [UIColor clearColor];
	title.textAlignment = NSTextAlignmentCenter;
	title.numberOfLines = 2;
	[box addSubview:title];
	UILabel *thanks = [[UILabel alloc] initWithFrame:CGRectMake(70, 106, 180, 58)];
	thanks.text = @"Thank you for downloading it. Have fun with the app!";
	thanks.font = [UIFont fontWithName:@"Helvetica" size:15];
	thanks.textColor = WAColor(0x5A5A5A);
	thanks.shadowColor = [UIColor whiteColor];
	thanks.shadowOffset = CGSizeMake(0, 1);
	thanks.backgroundColor = [UIColor clearColor];
	thanks.textAlignment = NSTextAlignmentCenter;
	thanks.numberOfLines = 3;
	[box addSubview:thanks];
	UILabel *sign = [[UILabel alloc] initWithFrame:CGRectMake(68, 168, 184, 24)];
	sign.text = @"– aronsz26";
	sign.font = [UIFont fontWithName:@"Georgia-Italic" size:17];
	sign.textColor = WAColor(0x6E6E6E);
	sign.shadowColor = [UIColor whiteColor];
	sign.shadowOffset = CGSizeMake(0, 1);
	sign.backgroundColor = [UIColor clearColor];
	sign.textAlignment = NSTextAlignmentCenter;
	[box addSubview:sign];

	// continue button
	UIButton *go = GreenButton(@"Continue", CGRectMake(31, CGRectGetMaxY(box.frame) + (top > 10 ? 26 : 14), 258, 41));
	[go addTarget:self action:@selector(next) forControlEvents:UIControlEventTouchUpInside];
	[v addSubview:go];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Welcome";
	self.navigationItem.backBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Welcome"
		style:UIBarButtonItemStyleBordered target:nil action:nil];
}

- (void)next {
	WAHowItWorksViewController *how = [[WAHowItWorksViewController alloc] init];
	how.finished = self.finished;
	[self.navigationController pushViewController:how animated:YES];
}

@end
