#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import "WAChatViewController.h"
#import "WAClient.h"
#import "WAAssets.h"
#import "WAUtil.h"
#import "WACall.h"
#import "WAInfoViewController.h"
#import "WAPrefs.h"
#import "WABubbles.h"
#import "WAReactions.h"

// 2.10 layout: GreenBubbleOut/GrayBubbleIn, time pill next to bubble, input bar at the bottom
static const CGFloat kMaxTextWidth = 200;
static const CGFloat kImageWidth = 200, kImageHeight = 150;
static const CGFloat kVoiceWidth = 196, kVoiceHeight = 42;
static const CGFloat kBarHeight = 40;
static const CGFloat kQuoteHeight = 40; // quote inside a reply
static const CGFloat kAttachHeight = 44; // attachments bar
static const CGFloat kReactionsHeight = 16; // reactions pill height
static const CGFloat kSwipeTrigger = 60; // swipe distance for reply/react

static UIFont *TextFont(void) { return [UIFont systemFontOfSize:16]; }
static UIFont *NameFont(void) { return [UIFont boldSystemFontOfSize:14]; }
static UIFont *TimeFont(void) { return [UIFont italicSystemFontOfSize:11]; }

static BOOL IsMedia(NSDictionary *m) {
	NSString *kind = m[@"kind"];
	return [kind isEqualToString:@"image"] || [kind isEqualToString:@"sticker"] || [kind isEqualToString:@"video"];
}

static BOOL IsVideo(NSDictionary *m) {
	return [m[@"kind"] isEqualToString:@"video"];
}

static BOOL IsVoice(NSDictionary *m) {
	return [m[@"kind"] isEqualToString:@"audio"];
}

static NSString *WADuration(NSInteger secs) {
	return [NSString stringWithFormat:@"%ld:%02ld", (long)(secs / 60), (long)(secs % 60)];
}

static NSString *BodyText(NSDictionary *m) {
	NSString *kind = m[@"kind"], *text = m[@"text"];
	if ([kind isEqualToString:@"text"] || IsMedia(m)) return text;
	if (IsVoice(m)) return @"";
	NSString *label = WAKindLabel(kind);
	return text.length ? [NSString stringWithFormat:@"%@: %@", label, text] : [NSString stringWithFormat:@"[%@]", label];
}

static NSDictionary *QuoteOf(NSDictionary *m) {
	id q = m[@"quote"];
	return [q isKindOfClass:[NSDictionary class]] ? q : nil;
}

static NSString *QuoteName(NSDictionary *q) {
	if ([q[@"fromMe"] boolValue]) return @"You";
	return [q[@"name"] length] ? q[@"name"] : [[q[@"sender"] componentsSeparatedByString:@"@"] firstObject];
}

// one line for a quote (text or "Photo" etc)
static NSString *QuoteLine(NSDictionary *q) {
	NSString *text = [[q[@"text"] componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
	if (text.length) return text;
	return [q[@"kind"] isEqualToString:@"text"] ? @"" : WAKindLabel(q[@"kind"]);
}

static NSArray *ReactionsOf(NSDictionary *m) {
	id r = m[@"reactions"];
	return [r isKindOfClass:[NSArray class]] && [r count] ? r : nil;
}

// top 3 emojis + count
static NSString *ReactionsText(NSArray *reactions) {
	NSCountedSet *set = [[NSCountedSet alloc] init];
	NSMutableArray *order = [NSMutableArray array];
	for (NSDictionary *r in reactions) {
		NSString *e = WAEmojiForDisplay(r[@"emoji"]);
		if (![set containsObject:e]) [order addObject:e];
		[set addObject:e];
	}
	[order sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(id a, id b) {
		NSUInteger ca = [set countForObject:a], cb = [set countForObject:b];
		return ca == cb ? NSOrderedSame : (ca > cb ? NSOrderedAscending : NSOrderedDescending);
	}];
	NSString *emojis = [[order subarrayWithRange:NSMakeRange(0, MIN(3, order.count))] componentsJoinedByString:@""];
	return reactions.count > 1 ? [NSString stringWithFormat:@"%@ %lu", emojis, (unsigned long)reactions.count] : emojis;
}

static BOOL IsCall(NSDictionary *m) {
	return [m[@"kind"] isEqualToString:@"call"];
}

// system lines ("You created group..."), centered, no icon
static BOOL IsSystem(NSDictionary *m) {
	return [m[@"kind"] isEqualToString:@"system"];
}

// phone app glyphs (device only), red for missed
static UIImage *CallGlyph(NSDictionary *m) {
	static NSCache *cache;
	if (!cache) cache = [[NSCache alloc] init];
	BOOL mine = [m[@"fromMe"] boolValue], missed = [m[@"text"] isEqualToString:@"missed"];
	NSString *key = mine ? @"out" : (missed ? @"missed" : @"in");
	UIImage *img = [cache objectForKey:key];
	if (img) return img;
	UIImage *src = WASystemImg(mine ? @"/Applications/MobilePhone.app/outgoingcall" : @"/Applications/MobilePhone.app/activecall");
	if (!src) return nil;
	if (mine) {
		img = src;
	} else { // tint + 12pt
		CGRect r = CGRectMake(0, 0, 12, 12);
		UIGraphicsBeginImageContextWithOptions(r.size, NO, 0);
		CGContextRef ctx = UIGraphicsGetCurrentContext();
		[src drawInRect:r];
		CGContextSetBlendMode(ctx, kCGBlendModeSourceIn);
		[(missed ? WAColor(0xD12F2F) : WAColor(0x6F7B8A)) setFill];
		CGContextFillRect(ctx, r);
		img = UIGraphicsGetImageFromCurrentImageContext();
		UIGraphicsEndImageContext();
	}
	[cache setObject:img forKey:key];
	return img;
}

static NSString *DayTitle(long long ts) {
	static NSDateFormatter *f;
	if (!f) {
		f = [[NSDateFormatter alloc] init];
		f.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_GB"];
		f.dateFormat = @"EEEE, d MMMM yyyy";
	}
	NSDate *d = [NSDate dateWithTimeIntervalSince1970:ts];
	NSCalendar *cal = [NSCalendar currentCalendar];
	NSDate *today = nil;
	[cal rangeOfUnit:NSDayCalendarUnit startDate:&today interval:NULL forDate:[NSDate date]];
	NSTimeInterval diff = [d timeIntervalSinceDate:today];
	if (diff >= 0) return @"Today";
	if (diff >= -86400) return @"Yesterday";
	return [f stringFromDate:d];
}

static NSString *DayKey(long long ts) {
	static NSDateFormatter *f;
	if (!f) {
		f = [[NSDateFormatter alloc] init];
		f.dateFormat = @"yyyyMMdd";
	}
	return [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:ts]];
}

// fallback bubble if assets missing
@interface WAPlainBubble : UIView
@property (nonatomic, strong) UIColor *fill;
@end

@implementation WAPlainBubble
- (void)drawRect:(CGRect)rect {
	UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, 2, 2) cornerRadius:12];
	[self.fill setFill];
	[path fill];
}
@end

@interface WAMessageCell : UITableViewCell
@property (nonatomic, strong) UIImageView *bubble;
@property (nonatomic, strong) WAPlainBubble *plainBubble;
@property (nonatomic, strong) UILabel *nameLabel, *bodyLabel, *timeLabel, *durationLabel, *dayLabel;
@property (nonatomic, strong) UIView *nameLine, *timePill, *callPill;
@property (nonatomic, strong) UILabel *callLabel, *callTime;
@property (nonatomic, strong) UIImageView *callIcon;
@property (nonatomic, strong) UIImageView *tick, *photo, *micIcon;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIImageView *videoPlay;
@property (nonatomic, strong) UIView *videoBar;
@property (nonatomic, strong) UILabel *videoLabel;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UIView *quoteBox, *quoteBar;
@property (nonatomic, strong) UILabel *quoteName, *quoteText;
@property (nonatomic, strong) UIButton *reactButton;
@end

@implementation WAMessageCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
	if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
		self.selectionStyle = UITableViewCellSelectionStyleNone;
		self.backgroundColor = [UIColor clearColor];
		UIView *c = self.contentView;
		_plainBubble = [[WAPlainBubble alloc] init];
		_plainBubble.backgroundColor = [UIColor clearColor];
		[c addSubview:_plainBubble];
		_bubble = [[UIImageView alloc] init];
		[c addSubview:_bubble];
		_nameLabel = [self label:NameFont() color:[UIColor blackColor]];
		_nameLine = [[UIView alloc] init];
		_nameLine.backgroundColor = [UIColor colorWithWhite:0 alpha:0.12];
		[c addSubview:_nameLine];
		_bodyLabel = [self label:TextFont() color:[UIColor blackColor]];
		_bodyLabel.numberOfLines = 0;
		_bodyLabel.lineBreakMode = NSLineBreakByWordWrapping;
		_photo = [[UIImageView alloc] init];
		_photo.contentMode = UIViewContentModeScaleAspectFill;
		_photo.clipsToBounds = YES;
		_photo.layer.cornerRadius = 5;
		_photo.backgroundColor = [UIColor colorWithWhite:0.85 alpha:1];
		[c addSubview:_photo];
		// play icon + duration bar
		_videoPlay = [[UIImageView alloc] init];
		_videoPlay.image = WAImg(@"VideoOverlayPlay");
		_videoPlay.contentMode = UIViewContentModeScaleAspectFit;
		[c addSubview:_videoPlay];
		_videoBar = [[UIView alloc] init];
		_videoBar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
		[c addSubview:_videoBar];
		_videoLabel = [[UILabel alloc] init];
		_videoLabel.font = [UIFont boldSystemFontOfSize:12];
		_videoLabel.textColor = [UIColor whiteColor];
		_videoLabel.backgroundColor = [UIColor clearColor];
		[c addSubview:_videoLabel];

		_playButton = [UIButton buttonWithType:UIButtonTypeCustom];
		[c addSubview:_playButton];
		_slider = [[UISlider alloc] init];
		UIImage *knob = WAImg(@"UIScrubberKnob");
		if (knob) {
			[_slider setThumbImage:knob forState:UIControlStateNormal];
			[_slider setMinimumTrackImage:WAStretch(@"UIScrubberBlueCap", 0, 4, 0, 0) forState:UIControlStateNormal];
			[_slider setMaximumTrackImage:WAStretch(@"UIScrubberWhiteCap", 0, 4, 0, 0) forState:UIControlStateNormal];
		}
		[c addSubview:_slider];
		_micIcon = [[UIImageView alloc] init];
		_micIcon.contentMode = UIViewContentModeCenter;
		[c addSubview:_micIcon];
		_durationLabel = [self label:[UIFont systemFontOfSize:11] color:WAColor(0x6D6D6D)];

		_timePill = [[UIView alloc] init];
		_timePill.backgroundColor = [UIColor colorWithRed:0.86 green:0.92 blue:0.97 alpha:0.85];
		_timePill.layer.cornerRadius = 8;
		[c addSubview:_timePill];
		_timeLabel = [self label:TimeFont() color:WAColor(0x4D5866)];
		_tick = [[UIImageView alloc] init];
		_tick.contentMode = UIViewContentModeCenter;
		[c addSubview:_tick];

		_dayLabel = [self label:[UIFont boldSystemFontOfSize:12] color:WAColor(0x4D5866)];
		_dayLabel.textAlignment = NSTextAlignmentCenter;
		_dayLabel.backgroundColor = [UIColor colorWithRed:0.86 green:0.92 blue:0.97 alpha:0.9];
		_dayLabel.layer.cornerRadius = 9;

		// calls look like the day titles (2.10 had no calls)
		_callPill = [[UIView alloc] init];
		_callPill.backgroundColor = [UIColor colorWithRed:0.86 green:0.92 blue:0.97 alpha:0.9];
		_callPill.layer.cornerRadius = 10;
		[c addSubview:_callPill];
		_callIcon = [[UIImageView alloc] init];
		_callIcon.contentMode = UIViewContentModeCenter;
		[c addSubview:_callIcon];
		_callLabel = [self label:[UIFont boldSystemFontOfSize:12] color:WAColor(0x4D5866)];
		_callTime = [self label:TimeFont() color:WAColor(0x4D5866)];

		// quote box with colored bar
		_quoteBox = [[UIView alloc] init];
		_quoteBox.backgroundColor = [UIColor colorWithWhite:0 alpha:0.07];
		_quoteBox.layer.cornerRadius = 4;
		_quoteBox.clipsToBounds = YES;
		[c addSubview:_quoteBox];
		_quoteBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 3, kQuoteHeight)];
		[_quoteBox addSubview:_quoteBar];
		_quoteName = [self label:[UIFont boldSystemFontOfSize:12] color:[UIColor blackColor]];
		[_quoteName removeFromSuperview];
		[_quoteBox addSubview:_quoteName];
		_quoteText = [self label:[UIFont systemFontOfSize:13] color:WAColor(0x5A5A5A)];
		[_quoteText removeFromSuperview];
		[_quoteBox addSubview:_quoteText];

		// reactions pill under the bubble
		_reactButton = [UIButton buttonWithType:UIButtonTypeCustom];
		_reactButton.backgroundColor = [UIColor whiteColor];
		_reactButton.layer.cornerRadius = 10;
		_reactButton.layer.borderWidth = 1;
		_reactButton.layer.borderColor = [UIColor colorWithWhite:0.75 alpha:1].CGColor;
		_reactButton.titleLabel.font = [UIFont systemFontOfSize:13];
		[_reactButton setTitleColor:WAColor(0x6D6D6D) forState:UIControlStateNormal];
		[c addSubview:_reactButton];
	}
	return self;
}

- (UILabel *)label:(UIFont *)font color:(UIColor *)color {
	UILabel *l = [[UILabel alloc] init];
	l.font = font;
	l.textColor = color;
	l.backgroundColor = [UIColor clearColor];
	[self.contentView addSubview:l];
	return l;
}

- (void)hideAll {
	for (UIView *v in self.contentView.subviews) v.hidden = YES;
}

@end

@implementation WAChatViewController {
	NSDictionary *_chat;
	NSString *_jid;
	BOOL _group;
	NSMutableArray *_messages; // oldest first
	NSMutableArray *_rows; // messages + day titles
	UITableView *_table;

	UIImageView *_bar;
	UIImageView *_fieldBG;
	UITextField *_field;
	UIButton *_sendButton, *_micButton, *_attachButton;
	UIView *_recordView;
	UILabel *_recordTime, *_slideLabel;
	UIImageView *_recordDot;

	UILabel *_titleLabel, *_subtitleLabel;
	NSString *_members;
	NSDictionary *_presence;

	NSCache *_images;
	NSNumber *_loadingVideo;
	NSMutableSet *_loadingImages;
	NSInteger _tempID;

	AVAudioPlayer *_player;
	NSNumber *_playingSeq;
	BOOL _loadingVoice;
	NSTimer *_progressTimer;
	NSCache *_voiceData;

	AVAudioRecorder *_recorder;
	NSTimer *_recordTimer;
	CGFloat _recordStartX;
	BOOL _recordCancelled;

	// attachments bar (reply + pending media)
	NSDictionary *_quote;
	NSMutableArray *_pending; // kind, data, preview, secs
	UIImageView *_attachBar;
	UIButton *_quoteButton, *_clipButton;
	UIImageView *_quoteBubble;
	UILabel *_quoteLabel;
	UIView *_attachDivider;
	UIScrollView *_thumbs;
	NSInteger _removeIndex;
	CGFloat _keyboardTop;

	NSDictionary *_menuMessage; // long press target
	NSIndexPath *_menuRow;
	NSIndexPath *_swipeRow; // swiped bubble
	UIImageView *_swipeIcon;
	BOOL _swipePassed;
	CGFloat _swipeMid;
	UIImage *_replyGlyph, *_reactGlyph;
	NSMutableSet *_prefetching;
}

- (instancetype)initWithChat:(NSDictionary *)chat {
	if ((self = [super init])) {
		_chat = chat;
		_jid = chat[@"jid"];
		_group = [chat[@"group"] boolValue];
		_messages = [NSMutableArray array];
		_rows = [NSMutableArray array];
		_images = [[NSCache alloc] init];
		_loadingImages = [NSMutableSet set];
		_voiceData = [[NSCache alloc] init];
		_pending = [NSMutableArray array];
		_prefetching = [NSMutableSet set];
		self.hidesBottomBarWhenPushed = YES;
	}
	return self;
}

- (NSString *)jid {
	return _jid;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[_progressTimer invalidate];
	[_recordTimer invalidate];
	_player.delegate = nil;
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[_table reloadData]; // bubble colors might have changed
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[self stopVoice];
	if (_recorder) [self finishRecording:NO];
}

#pragma mark - Views

- (void)loadView {
	UIView *v = [[UIView alloc] initWithFrame:[UIScreen mainScreen].applicationFrame];
	v.backgroundColor = WAColor(0xE5DFD5);
	CGRect b = v.bounds;
	// wallpaper
	NSString *wallpaper = WAPrefString(WAPrefWallpaper);
	UIImage *wp = wallpaper ? [UIImage imageWithContentsOfFile:wallpaper] : nil;
	if (wp) {
		UIImageView *bg = [[UIImageView alloc] initWithFrame:b];
		bg.image = wp;
		bg.contentMode = UIViewContentModeScaleAspectFill;
		bg.clipsToBounds = YES;
		bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[v addSubview:bg];
	}
	_table = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, b.size.width, b.size.height - kBarHeight) style:UITableViewStylePlain];
	_table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_table.backgroundColor = [UIColor clearColor];
	_table.separatorStyle = UITableViewCellSeparatorStyleNone;
	_table.dataSource = self;
	_table.delegate = self;
	[v addSubview:_table];
	[v addSubview:[self attachmentsBar:b]];
	[v addSubview:[self inputBar:b]];
	self.view = v;
	[self setupTitle];
	UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(pressed:)];
	[_table addGestureRecognizer:press];
	UIPanGestureRecognizer *swipe = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(swiped:)];
	swipe.delegate = self;
	[_table addGestureRecognizer:swipe];
}

- (UIView *)inputBar:(CGRect)b {
	CGFloat w = b.size.width;
	_bar = [[UIImageView alloc] initWithFrame:CGRectMake(0, b.size.height - kBarHeight, w, kBarHeight)];
	_bar.userInteractionEnabled = YES;
	_bar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
	_bar.image = WAStretch(@"ChatInputControlsBG", 0, 0, 0, 0);
	if (!_bar.image) _bar.backgroundColor = WAColor(0xDADFE6);

	_attachButton = [UIButton buttonWithType:UIButtonTypeCustom];
	_attachButton.frame = CGRectMake(4, 4, 32, 32);
	[_attachButton setBackgroundImage:WAImg(@"ChatButtonNormal") forState:UIControlStateNormal];
	[_attachButton setBackgroundImage:WAImg(@"ChatButtonPressed") forState:UIControlStateHighlighted];
	[_attachButton setImage:[self attachGlyph] forState:UIControlStateNormal];
	[_attachButton addTarget:self action:@selector(attachTapped) forControlEvents:UIControlEventTouchUpInside];
	[_bar addSubview:_attachButton];

	// the image is 40 high with bar around the field, never squeeze it
	_fieldBG = [[UIImageView alloc] initWithFrame:CGRectMake(36, 0, w - 36 - 36, kBarHeight)];
	_fieldBG.image = WAStretch(@"ChatInputFieldBG", 20, 20, 19, 19);
	_fieldBG.userInteractionEnabled = YES;
	[_bar addSubview:_fieldBG];
	_field = [[UITextField alloc] initWithFrame:CGRectMake(14, 8, _fieldBG.bounds.size.width - 28, 25)];
	_field.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	_field.borderStyle = _fieldBG.image ? UITextBorderStyleNone : UITextBorderStyleRoundedRect;
	_field.font = [UIFont systemFontOfSize:16];
	_field.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
	_field.returnKeyType = UIReturnKeySend;
	_field.enablesReturnKeyAutomatically = YES;
	_field.delegate = self;
	[_field addTarget:self action:@selector(textChanged) forControlEvents:UIControlEventEditingChanged];
	[_fieldBG addSubview:_field];

	_sendButton = [UIButton buttonWithType:UIButtonTypeCustom];
	_sendButton.frame = CGRectMake(w - 66, 0, 66, 40);
	[_sendButton setBackgroundImage:WAImg(@"SendButtonNormal") forState:UIControlStateNormal];
	[_sendButton setBackgroundImage:WAImg(@"SendButtonPressed") forState:UIControlStateHighlighted];
	[_sendButton setTitle:@"Send" forState:UIControlStateNormal];
	_sendButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
	_sendButton.titleLabel.shadowOffset = CGSizeMake(0, -1);
	[_sendButton setTitleShadowColor:[UIColor colorWithWhite:0 alpha:0.35] forState:UIControlStateNormal];
	if (!WAImg(@"SendButtonNormal")) [_sendButton setTitleColor:WAColor(0x2470D8) forState:UIControlStateNormal];
	[_sendButton addTarget:self action:@selector(send) forControlEvents:UIControlEventTouchUpInside];
	[_bar addSubview:_sendButton];

	_micButton = [UIButton buttonWithType:UIButtonTypeCustom];
	_micButton.frame = CGRectMake(w - 37, 6, 31, 28);
	[_micButton setBackgroundImage:WAImg(@"MicBtn") forState:UIControlStateNormal];
	[_micButton setImage:WAImg(@"MicRecBtn") forState:UIControlStateNormal];
	if (!WAImg(@"MicBtn")) [_micButton setTitle:@"🎤" forState:UIControlStateNormal];
	[_micButton addTarget:self action:@selector(micDown:withEvent:) forControlEvents:UIControlEventTouchDown];
	[_micButton addTarget:self action:@selector(micMove:withEvent:) forControlEvents:UIControlEventTouchDragInside | UIControlEventTouchDragOutside];
	[_micButton addTarget:self action:@selector(micUp:withEvent:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
	[_micButton addTarget:self action:@selector(micCancel) forControlEvents:UIControlEventTouchCancel];
	[_bar addSubview:_micButton];

	_recordView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w - 40, kBarHeight)];
	_recordView.backgroundColor = [UIColor clearColor];
	_recordView.hidden = YES;
	UIImageView *recBG = [[UIImageView alloc] initWithFrame:_recordView.bounds];
	recBG.image = _bar.image;
	recBG.backgroundColor = _bar.backgroundColor;
	[_recordView addSubview:recBG];
	_recordDot = [[UIImageView alloc] initWithFrame:CGRectMake(10, 5, 18, 29)];
	_recordDot.image = WAImg(@"MicRecRed");
	_recordDot.contentMode = UIViewContentModeScaleAspectFit;
	[_recordView addSubview:_recordDot];
	_recordTime = [[UILabel alloc] initWithFrame:CGRectMake(34, 10, 50, 20)];
	_recordTime.font = [UIFont boldSystemFontOfSize:16];
	_recordTime.backgroundColor = [UIColor clearColor];
	[_recordView addSubview:_recordTime];
	_slideLabel = [[UILabel alloc] initWithFrame:CGRectMake(90, 10, w - 140, 20)];
	_slideLabel.font = [UIFont systemFontOfSize:14];
	_slideLabel.textColor = WAColor(0x6D6D6D);
	_slideLabel.backgroundColor = [UIColor clearColor];
	_slideLabel.textAlignment = NSTextAlignmentCenter;
	_slideLabel.text = @"‹  slide to cancel";
	[_recordView addSubview:_slideLabel];
	[_bar addSubview:_recordView];

	[self textChanged];
	return _bar;
}

#pragma mark - Attachments bar

// bar above the input: quote + paperclip + pending pics
- (UIView *)attachmentsBar:(CGRect)b {
	CGFloat w = b.size.width;
	_attachBar = [[UIImageView alloc] initWithFrame:CGRectMake(0, b.size.height - kBarHeight - kAttachHeight, w, kAttachHeight)];
	_attachBar.userInteractionEnabled = YES;
	_attachBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	// stretch it, tiling gives stripes
	_attachBar.image = WAImg(@"ChatInputControlsBG");
	_attachBar.contentMode = UIViewContentModeScaleToFill;
	if (!_attachBar.image) _attachBar.backgroundColor = WAColor(0xDADFE6);
	_attachBar.hidden = YES;

	_quoteButton = [UIButton buttonWithType:UIButtonTypeCustom];
	_quoteButton.frame = CGRectMake(2, 6, 34, 32);
	[_quoteButton setImage:[self quoteGlyph] forState:UIControlStateNormal];
	[_quoteButton addTarget:self action:@selector(cancelQuote) forControlEvents:UIControlEventTouchUpInside];
	[_attachBar addSubview:_quoteButton];
	_quoteBubble = [[UIImageView alloc] init];
	_quoteBubble.userInteractionEnabled = YES;
	[_quoteBubble addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showQuoted)]];
	[_attachBar addSubview:_quoteBubble];
	_quoteLabel = [[UILabel alloc] init];
	_quoteLabel.font = [UIFont systemFontOfSize:15];
	_quoteLabel.backgroundColor = [UIColor clearColor];
	_quoteLabel.lineBreakMode = NSLineBreakByTruncatingTail;
	[_quoteBubble addSubview:_quoteLabel];
	_attachDivider = [[UIView alloc] init];
	_attachDivider.backgroundColor = [UIColor colorWithWhite:0 alpha:0.18];
	[_attachBar addSubview:_attachDivider];

	_clipButton = [UIButton buttonWithType:UIButtonTypeCustom];
	[_clipButton setImage:[self clipGlyph] forState:UIControlStateNormal];
	[_clipButton addTarget:self action:@selector(attachTapped) forControlEvents:UIControlEventTouchUpInside];
	[_attachBar addSubview:_clipButton];
	_thumbs = [[UIScrollView alloc] init];
	_thumbs.showsHorizontalScrollIndicator = NO;
	[_attachBar addSubview:_thumbs];
	return _attachBar;
}

// quote icon
- (UIImage *)quoteGlyph {
	UIGraphicsBeginImageContextWithOptions(CGSizeMake(26, 24), NO, 0);
	UIColor *grey = WAColor(0x7E8690);
	[grey setFill];
	[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, 22, 20)] fill];
	UIBezierPath *tail = [UIBezierPath bezierPath];
	[tail moveToPoint:CGPointMake(14, 19)];
	[tail addLineToPoint:CGPointMake(24, 23.5)];
	[tail addLineToPoint:CGPointMake(20, 15)];
	[tail fill];
	[[UIColor whiteColor] set];
	[@"\u201C" drawInRect:CGRectMake(1, -2, 22, 24) withFont:[UIFont boldSystemFontOfSize:24] lineBreakMode:NSLineBreakByClipping
		alignment:NSTextAlignmentCenter];
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

// paperclip
- (UIImage *)clipGlyph {
	UIGraphicsBeginImageContextWithOptions(CGSizeMake(28, 32), NO, 0);
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	CGContextTranslateCTM(ctx, 14, 16);
	CGContextRotateCTM(ctx, M_PI / 5);
	UIBezierPath *p = [UIBezierPath bezierPath];
	[p moveToPoint:CGPointMake(2, 6)];
	[p addLineToPoint:CGPointMake(2, -8)];
	[p addArcWithCenter:CGPointMake(-1.5, -8) radius:3.5 startAngle:0 endAngle:M_PI clockwise:NO];
	[p addLineToPoint:CGPointMake(-5, 9)];
	[p addArcWithCenter:CGPointMake(0, 9) radius:5 startAngle:M_PI endAngle:0 clockwise:NO];
	[p addLineToPoint:CGPointMake(5, -11)];
	p.lineWidth = 2;
	p.lineCapStyle = kCGLineCapRound;
	[WAColor(0x7D858F) setStroke];
	[p stroke];
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

- (void)updateAttachmentsBar {
	CGFloat w = _attachBar.bounds.size.width, x = 4;
	BOOL quote = _quote != nil, pictures = _pending.count > 0;
	_quoteButton.hidden = _quoteBubble.hidden = !quote;
	_attachDivider.hidden = !(quote && pictures);
	_clipButton.hidden = _thumbs.hidden = !pictures;
	if (quote) {
		BOOL mine = [_quote[@"fromMe"] boolValue];
		NSString *text = QuoteLine(@{@"text": _quote[@"text"] ?: @"", @"kind": _quote[@"kind"] ?: @"text"});
		CGFloat maxW = pictures ? 150 : w - 80;
		CGFloat tw = MIN(maxW, MAX(30, ceilf([text sizeWithFont:_quoteLabel.font].width)));
		NSString *color = WABubbleColorName(_jid, mine);
		_quoteBubble.image = WABubbleImage(color, NO); // tail always left
		_quoteBubble.backgroundColor = _quoteBubble.image ? nil : WABubbleFill(color, mine);
		_quoteBubble.frame = CGRectMake(36, 5, tw + 31, 34);
		_quoteLabel.frame = CGRectMake(21, 6, tw, 20);
		_quoteLabel.text = text;
		x = CGRectGetMaxX(_quoteBubble.frame) + 6;
		_attachDivider.frame = CGRectMake(x, 6, 1, kAttachHeight - 12);
		x += 6;
	}
	_clipButton.frame = CGRectMake(x, 6, 30, 32);
	x += 34;
	_thumbs.frame = CGRectMake(x, 0, w - x, kAttachHeight);
	for (UIView *v in [_thumbs.subviews copy]) [v removeFromSuperview];
	CGFloat tx = 0;
	for (NSUInteger i = 0; i < _pending.count; i++) {
		NSDictionary *item = _pending[i];
		UIButton *t = [UIButton buttonWithType:UIButtonTypeCustom];
		t.frame = CGRectMake(tx, 4, 36, 36);
		t.layer.cornerRadius = 7;
		t.layer.borderWidth = 1;
		t.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.3].CGColor;
		t.clipsToBounds = YES;
		t.imageView.contentMode = UIViewContentModeScaleAspectFill;
		[t setImage:item[@"preview"] forState:UIControlStateNormal];
		if ([item[@"kind"] isEqualToString:@"video"]) {
			UILabel *play = [[UILabel alloc] initWithFrame:CGRectMake(0, 24, 36, 12)];
			play.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
			play.textColor = [UIColor whiteColor];
			play.font = [UIFont boldSystemFontOfSize:10];
			play.textAlignment = NSTextAlignmentCenter;
			play.text = [NSString stringWithFormat:@"\u25B6 %@", WADuration([item[@"secs"] integerValue])];
			[t addSubview:play];
		}
		t.tag = i;
		[t addTarget:self action:@selector(thumbTapped:) forControlEvents:UIControlEventTouchUpInside];
		[_thumbs addSubview:t];
		tx += 42;
	}
	_thumbs.contentSize = CGSizeMake(tx, kAttachHeight);
	[self layoutBottom];
	[self textChanged];
}

- (void)cancelQuote {
	_quote = nil;
	[self updateAttachmentsBar];
}

- (void)showQuoted {
	NSIndexPath *ip = [self indexPathForMessageID:_quote[@"id"]];
	if (ip) [_table scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
}

- (void)thumbTapped:(UIButton *)b {
	_removeIndex = b.tag;
	[_field resignFirstResponder];
	UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:@"Cancel"
		destructiveButtonTitle:@"Remove Attachment" otherButtonTitles:nil];
	[sheet showInView:self.view];
}

// layout above the keyboard
- (void)layoutBottom {
	CGFloat bottom = _keyboardTop > 0 ? _keyboardTop : self.view.bounds.size.height;
	CGRect bar = _bar.frame;
	bar.origin.y = bottom - bar.size.height;
	_bar.frame = bar;
	BOOL attach = _quote || _pending.count;
	_attachBar.hidden = !attach;
	CGRect a = _attachBar.frame;
	a.origin.y = bar.origin.y - kAttachHeight;
	_attachBar.frame = a;
	CGRect t = _table.frame;
	t.size.height = attach ? a.origin.y : bar.origin.y;
	_table.frame = t;
}

// little blue arrow
- (UIImage *)attachGlyph {
	UIGraphicsBeginImageContextWithOptions(CGSizeMake(20, 20), NO, 0);
	UIColor *blue = WAColor(0x4C78B5);
	UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, 18, 18)];
	circle.lineWidth = 1.6;
	[blue setStroke];
	[circle stroke];
	UIBezierPath *arrow = [UIBezierPath bezierPath];
	[arrow moveToPoint:CGPointMake(10, 15)];
	[arrow addLineToPoint:CGPointMake(10, 5.5)];
	[arrow moveToPoint:CGPointMake(6, 9.5)];
	[arrow addLineToPoint:CGPointMake(10, 5.5)];
	[arrow addLineToPoint:CGPointMake(14, 9.5)];
	arrow.lineWidth = 2;
	arrow.lineCapStyle = kCGLineCapRound;
	arrow.lineJoinStyle = kCGLineJoinRound;
	[arrow stroke];
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

- (void)setupTitle {
	// narrower title so ios 6 doesn't drop the call button
	UIView *tv = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _group ? 190 : 140, 44)];
	_titleLabel = [[UILabel alloc] init];
	_titleLabel.font = [UIFont boldSystemFontOfSize:18];
	_titleLabel.adjustsFontSizeToFitWidth = YES;
	_titleLabel.minimumScaleFactor = 0.75;
	_subtitleLabel = [[UILabel alloc] init];
	_subtitleLabel.font = [UIFont systemFontOfSize:13];
	for (UILabel *l in @[_titleLabel, _subtitleLabel]) {
		l.backgroundColor = [UIColor clearColor];
		l.textColor = [UIColor whiteColor];
		l.shadowColor = [UIColor colorWithWhite:0 alpha:0.45];
		l.shadowOffset = CGSizeMake(0, -1);
		l.textAlignment = NSTextAlignmentCenter;
		l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
		[tv addSubview:l];
	}
	_titleLabel.text = _chat[@"name"];
	self.navigationItem.titleView = tv;
	[self layoutTitle];

	if (_group) {
		self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Info"
			style:UIBarButtonItemStyleBordered target:self action:@selector(showInfo)];
	} else {
		UIImageView *pic = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 32, 32)];
		pic.contentMode = UIViewContentModeScaleAspectFill;
		pic.clipsToBounds = YES;
		pic.layer.cornerRadius = 4;
		pic.layer.borderWidth = 1;
		pic.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.35].CGColor;
		pic.image = [[WAClient shared] cachedAvatarFor:_jid] ?: WAImg(@"EmptyContact");
		pic.userInteractionEnabled = YES; // avatar -> contact info
		[pic addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showInfo)]];
		[[WAClient shared] avatarFor:_jid completion:^(UIImage *image) {
			if (image) pic.image = image;
		}];
		UIBarButtonItem *call = [[UIBarButtonItem alloc] initWithImage:[self phoneGlyph]
			style:UIBarButtonItemStyleBordered target:self action:@selector(startCall)];
		self.navigationItem.rightBarButtonItems = @[[[UIBarButtonItem alloc] initWithCustomView:pic], call];
	}
}

// handset glyph for the bar
- (UIImage *)phoneGlyph {
	UIImage *glyph = WASystemImg(@"/System/Library/PrivateFrameworks/TelephonyUI.framework/answer");
	if (!glyph) return nil;
	CGSize size = CGSizeMake(20, 19);
	UIGraphicsBeginImageContextWithOptions(size, NO, 0);
	[glyph drawInRect:CGRectMake(0, 0, size.width, size.height)];
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

// voice/video sheet (voice only while video is hidden)
- (void)startCall {
	[self.view endEditing:YES];
	if (!WAVideoCallsEnabled()) {
		[[WACall shared] callJID:_jid name:_chat[@"name"] video:NO];
		return;
	}
	UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:nil
		destructiveButtonTitle:nil otherButtonTitles:@"Voice Call", @"Video Call", nil];
	sheet.cancelButtonIndex = [sheet addButtonWithTitle:@"Cancel"];
	[sheet showInView:self.view];
}

- (void)layoutTitle {
	CGFloat w = self.navigationItem.titleView.bounds.size.width;
	BOOL sub = _subtitleLabel.text.length > 0;
	_subtitleLabel.hidden = !sub;
	_titleLabel.frame = sub ? CGRectMake(0, 3, w, 22) : CGRectMake(0, 0, w, 44);
	_subtitleLabel.frame = CGRectMake(0, 24, w, 16);
}

- (void)showInfo {
	[_field resignFirstResponder];
	[self.navigationController pushViewController:[[WAInfoViewController alloc] initWithJID:_jid name:_chat[@"name"]
		group:_group] animated:YES];
}

#pragma mark - Loading

- (void)viewDidLoad {
	[super viewDidLoad];
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillShowNotification object:nil];
	[nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillHideNotification object:nil];
	[nc addObserver:self selector:@selector(updatesArrived:) name:WAClientUpdatesNotification object:nil];
	[self load];
	[self loadInfo];
}

- (void)load {
	[[WAClient shared] get:@"/api/messages" params:@{@"chat": _jid, @"limit": @80} completion:^(id json, NSError *error) {
		if (error) return;
		[self->_messages setArray:json[@"messages"]];
		[self rebuildRows];
		[self scrollToBottom:NO];
		[self markRead];
	}];
}

- (void)loadInfo {
	[[WAClient shared] get:@"/api/chatinfo" params:@{@"chat": _jid} completion:^(id json, NSError *error) {
		if (error) return;
		if ([json[@"members"] isKindOfClass:[NSArray class]]) {
			self->_members = [json[@"members"] componentsJoinedByString:@", "];
		}
		if ([json[@"presence"] isKindOfClass:[NSDictionary class]]) self->_presence = json[@"presence"];
		[self updateSubtitle];
	}];
}

- (void)updateSubtitle {
	NSDictionary *p = _presence;
	NSString *text = nil;
	if ([p[@"typing"] boolValue]) {
		NSString *who = p[@"typingName"];
		text = who.length ? [NSString stringWithFormat:@"%@ is typing...", who] : @"typing...";
	} else if (_group) {
		text = _members;
	} else if ([p[@"online"] boolValue]) {
		text = @"online";
	} else if ([p[@"lastSeen"] longLongValue] > 0) {
		text = WALastSeen([p[@"lastSeen"] longLongValue]);
	}
	_subtitleLabel.text = text;
	[self layoutTitle];
}

- (void)markRead {
	[[WAClient shared] post:@"/api/read" params:@{@"chat": _jid} completion:^(id json, NSError *error) {}];
}

- (void)rebuildRows {
	[_rows removeAllObjects];
	NSString *lastDay = nil;
	for (NSDictionary *m in _messages) {
		NSString *day = DayKey([m[@"ts"] longLongValue]);
		if (![day isEqualToString:lastDay]) {
			[_rows addObject:DayTitle([m[@"ts"] longLongValue])];
			lastDay = day;
		}
		[_rows addObject:m];
	}
	[_table reloadData];
}

- (void)scrollToBottom:(BOOL)animated {
	if (!_rows.count) return;
	[_table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:_rows.count - 1 inSection:0]
		atScrollPosition:UITableViewScrollPositionBottom animated:animated];
}

- (void)updatesArrived:(NSNotification *)note {
	for (NSDictionary *p in note.userInfo[@"presence"]) {
		if ([p[@"chat"] isEqualToString:_jid]) {
			_presence = p;
			[self updateSubtitle];
		}
	}
	BOOL changed = NO, added = NO, incoming = NO;
	for (NSDictionary *m in note.userInfo[@"messages"]) {
		if (![m[@"chat"] isEqualToString:_jid]) continue;
		changed = YES;
		NSUInteger idx = [self indexOfMessage:m];
		if (idx != NSNotFound) {
			_messages[idx] = m;
		} else {
			[_messages addObject:m];
			added = YES;
			if (![m[@"fromMe"] boolValue]) incoming = YES;
		}
	}
	if (!changed) return;
	[_messages sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
		long long ta = [a[@"ts"] longLongValue], tb = [b[@"ts"] longLongValue];
		if (ta != tb) return ta < tb ? NSOrderedAscending : NSOrderedDescending;
		return [a[@"seq"] compare:b[@"seq"]];
	}];
	[self rebuildRows];
	if (added) [self scrollToBottom:YES];
	if (incoming) [self markRead];
}

// match by seq or by wa id (for our own pending copy)
- (NSUInteger)indexOfMessage:(NSDictionary *)m {
	return [_messages indexOfObjectPassingTest:^BOOL(NSDictionary *o, NSUInteger i, BOOL *stop) {
		return [o[@"seq"] isEqual:m[@"seq"]] || [o[@"id"] isEqualToString:m[@"id"]];
	}];
}

- (NSIndexPath *)indexPathForSeq:(NSNumber *)seq {
	NSUInteger idx = [_rows indexOfObjectPassingTest:^BOOL(id o, NSUInteger i, BOOL *stop) {
		return [o isKindOfClass:[NSDictionary class]] && [o[@"seq"] isEqual:seq];
	}];
	return idx == NSNotFound ? nil : [NSIndexPath indexPathForRow:idx inSection:0];
}

- (NSIndexPath *)indexPathForMessageID:(NSString *)msgID {
	if (!msgID) return nil;
	NSUInteger idx = [_rows indexOfObjectPassingTest:^BOOL(id o, NSUInteger i, BOOL *stop) {
		return [o isKindOfClass:[NSDictionary class]] && [o[@"id"] isEqualToString:msgID];
	}];
	return idx == NSNotFound ? nil : [NSIndexPath indexPathForRow:idx inSection:0];
}

- (void)reloadSeq:(NSNumber *)seq {
	NSIndexPath *ip = seq ? [self indexPathForSeq:seq] : nil;
	if (ip && [[_table indexPathsForVisibleRows] containsObject:ip]) {
		[_table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
	}
}

#pragma mark - Sending text

- (void)textChanged {
	BOOL hasText = [_field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length > 0
		|| _pending.count > 0;
	_sendButton.hidden = !hasText;
	_micButton.hidden = hasText;
	CGFloat w = _bar.bounds.size.width;
	_fieldBG.frame = CGRectMake(36, 0, (hasText ? w - 64 : w - 37) - 36, kBarHeight);
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
	[self send];
	return NO;
}

- (void)insertTemp:(NSDictionary *)temp request:(void (^)(WAJSONBlock done))request {
	[_messages addObject:temp];
	[self rebuildRows];
	[self scrollToBottom:YES];
	request(^(id json, NSError *error) {
		NSUInteger idx = [self->_messages indexOfObject:temp];
		if (idx == NSNotFound) return;
		if (error) {
			[self->_messages removeObjectAtIndex:idx];
			[self rebuildRows];
			[[[UIAlertView alloc] initWithTitle:@"Not sent" message:error.localizedDescription delegate:nil
				cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
			return;
		}
		// long poll might have it already
		NSUInteger dup = [self indexOfMessage:json];
		if (dup != NSNotFound && dup != idx) {
			[self->_messages removeObjectAtIndex:idx];
		} else {
			self->_messages[idx] = json;
		}
		[self rebuildRows];
	});
}

- (NSDictionary *)tempMessage:(NSString *)kind text:(NSString *)text secs:(NSInteger)secs {
	return [self tempMessage:kind text:text secs:secs quote:nil];
}

- (NSDictionary *)tempMessage:(NSString *)kind text:(NSString *)text secs:(NSInteger)secs quote:(NSDictionary *)quote {
	_tempID++;
	NSMutableDictionary *m = [@{@"seq": @(-_tempID), @"id": [NSString stringWithFormat:@"temp-%ld", (long)_tempID],
		@"chat": _jid, @"fromMe": @YES, @"kind": kind, @"text": text, @"secs": @(secs),
		@"ts": @((long long)[[NSDate date] timeIntervalSince1970]), @"status": @0} mutableCopy];
	if (quote) m[@"quote"] = quote;
	return m;
}

// temp quote until the bridge copy arrives
- (NSDictionary *)quoteFor:(NSDictionary *)m {
	return @{@"id": m[@"id"] ?: @"", @"sender": m[@"sender"] ?: @"", @"name": m[@"name"] ?: _chat[@"name"] ?: @"",
		@"fromMe": m[@"fromMe"] ?: @NO, @"kind": m[@"kind"] ?: @"text", @"text": m[@"text"] ?: @""};
}

// text first, then media. quote goes with the first one
- (void)send {
	NSString *text = [_field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (!text.length && !_pending.count) return;
	NSDictionary *quote = _quote ? [self quoteFor:_quote] : nil;
	NSArray *pending = [_pending copy];
	_field.text = @"";
	_quote = nil;
	[_pending removeAllObjects];
	[self updateAttachmentsBar];
	NSString *jid = _jid;
	if (text.length) {
		NSMutableDictionary *params = [@{@"chat": jid, @"text": text} mutableCopy];
		if (quote) params[@"quote"] = quote[@"id"];
		[self insertTemp:[self tempMessage:@"text" text:text secs:0 quote:quote] request:^(WAJSONBlock done) {
			[[WAClient shared] post:@"/api/send" params:params completion:done];
		}];
		quote = nil;
	}
	for (NSDictionary *item in pending) {
		if ([item[@"kind"] isEqualToString:@"video"]) {
			[self sendVideo:item[@"data"] preview:item[@"preview"] secs:[item[@"secs"] integerValue] quote:quote];
		} else {
			[self sendImage:item[@"data"] preview:item[@"preview"] quote:quote];
		}
		quote = nil;
	}
}

- (void)keyboardWillChange:(NSNotification *)note {
	CGRect kb = [self.view convertRect:[note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil];
	BOOL showing = [note.name isEqualToString:UIKeyboardWillShowNotification];
	_keyboardTop = showing ? kb.origin.y : 0;
	[UIView animateWithDuration:[note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue] delay:0
		options:([note.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue] << 16) animations:^{
			[self layoutBottom];
		} completion:nil];
	if (showing) [self scrollToBottom:YES];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
	[_field resignFirstResponder];
}

#pragma mark - Layout

- (BOOL)showsName:(NSDictionary *)m {
	return _group && ![m[@"fromMe"] boolValue] && [m[@"name"] length] > 0;
}

// content size without bubble margins
- (CGSize)contentSizeFor:(NSDictionary *)m textSize:(CGSize *)textSizeOut {
	NSString *body = BodyText(m);
	CGSize text = CGSizeZero;
	if (body.length) {
		text = [body sizeWithFont:TextFont() constrainedToSize:CGSizeMake(kMaxTextWidth, 10000) lineBreakMode:NSLineBreakByWordWrapping];
		text.width = ceilf(text.width);
		text.height = ceilf(text.height);
	}
	if (textSizeOut) *textSizeOut = text;
	CGFloat w = text.width, h = text.height;
	if ([self showsName:m]) {
		w = MAX(w, MIN(kMaxTextWidth, [[m[@"name"] stringByAppendingString:@":"] sizeWithFont:NameFont()].width));
		h += 22;
	}
	NSDictionary *q = QuoteOf(m);
	if (q) {
		CGFloat qw = MAX([QuoteName(q) sizeWithFont:[UIFont boldSystemFontOfSize:12]].width,
			[QuoteLine(q) sizeWithFont:[UIFont systemFontOfSize:13]].width) + 14;
		w = MAX(w, MIN(kMaxTextWidth, MAX(120, ceilf(qw))));
		h += kQuoteHeight + 4;
	}
	if (IsMedia(m)) {
		w = MAX(w, kImageWidth);
		h += kImageHeight + (text.height ? 4 : 0);
	}
	if (IsVoice(m)) {
		w = MAX(w, kVoiceWidth);
		h += kVoiceHeight;
	}
	return CGSizeMake(MAX(w, 14), MAX(h, 20));
}

- (CGSize)bubbleSizeFor:(NSDictionary *)m textSize:(CGSize *)textSizeOut {
	CGSize c = [self contentSizeFor:m textSize:textSizeOut];
	return CGSizeMake(c.width + 31, c.height + 15);
}

- (void)layoutCall:(NSDictionary *)m inCell:(WAMessageCell *)cell width:(CGFloat)width {
	BOOL missed = [m[@"text"] isEqualToString:@"missed"];
	cell.callLabel.text = IsSystem(m) ? m[@"text"] : WACallText(m);
	cell.callLabel.textColor = missed ? WAColor(0xD12F2F) : WAColor(0x4D5866);
	cell.callTime.text = [self timeText:m];
	cell.callIcon.image = IsSystem(m) ? nil : CallGlyph(m);
	CGFloat iw = cell.callIcon.image ? 12 + 5 : 0;
	CGFloat lw = MIN(ceilf([cell.callLabel.text sizeWithFont:cell.callLabel.font].width), width - 110);
	CGFloat tw = ceilf([cell.callTime.text sizeWithFont:cell.callTime.font].width);
	CGFloat w = 10 + iw + lw + 6 + tw + 10;
	CGFloat x = floorf((width - w) / 2);
	cell.callPill.frame = CGRectMake(x, 5, w, 20);
	cell.callIcon.frame = CGRectMake(x + 10, 5, 12, 20);
	cell.callLabel.frame = CGRectMake(x + 10 + iw, 5, lw, 20);
	cell.callTime.frame = CGRectMake(x + 10 + iw + lw + 6, 5, tw, 20);
	for (UIView *v in @[cell.callPill, cell.callIcon, cell.callLabel, cell.callTime]) v.hidden = NO;
}

- (NSString *)timeText:(NSDictionary *)m {
	return WAClockTime([m[@"ts"] longLongValue]);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return _rows.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
	id row = _rows[indexPath.row];
	if ([row isKindOfClass:[NSString class]]) return 32;
	if (IsCall(row) || IsSystem(row)) return 30;
	return [self bubbleSizeFor:row textSize:NULL].height + 4 + (ReactionsOf(row) ? kReactionsHeight : 0);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	WAMessageCell *cell = [tableView dequeueReusableCellWithIdentifier:@"msg"];
	if (!cell) cell = [[WAMessageCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"msg"];
	[cell hideAll];
	cell.contentView.transform = CGAffineTransformIdentity;
	cell.contentView.layer.shouldRasterize = NO;
	CGFloat width = tableView.bounds.size.width;
	id row = _rows[indexPath.row];
	if ([row isKindOfClass:[NSString class]]) {
		cell.dayLabel.hidden = NO;
		cell.dayLabel.text = row;
		CGFloat w = [row sizeWithFont:cell.dayLabel.font].width + 20;
		cell.dayLabel.frame = CGRectMake(floorf((width - w) / 2), 7, w, 19);
		return cell;
	}
	NSDictionary *m = row;
	if (IsCall(m) || IsSystem(m)) {
		[self layoutCall:m inCell:cell width:width];
		return cell;
	}
	BOOL mine = [m[@"fromMe"] boolValue];
	CGSize textSize;
	CGSize size = [self bubbleSizeFor:m textSize:&textSize];
	CGRect bubble = CGRectMake(mine ? width - size.width - 3 : 3, 2, size.width, size.height);
	// per chat color or default
	NSString *color = WABubbleColorName(_jid, mine);
	UIImage *bubbleImage = WABubbleImage(color, mine);
	if (bubbleImage) {
		cell.bubble.hidden = NO;
		cell.bubble.image = bubbleImage;
		cell.bubble.frame = bubble;
	} else {
		cell.plainBubble.hidden = NO;
		cell.plainBubble.fill = WABubbleFill(color, mine);
		cell.plainBubble.frame = bubble;
		[cell.plainBubble setNeedsDisplay];
	}

	// wider margin on the tail side
	CGFloat x = bubble.origin.x + (mine ? 10 : 21);
	CGFloat contentW = size.width - 31;
	CGFloat y = bubble.origin.y + 6;
	if ([self showsName:m]) {
		cell.nameLabel.hidden = cell.nameLine.hidden = NO;
		cell.nameLabel.text = [m[@"name"] stringByAppendingString:@":"];
		cell.nameLabel.textColor = WANameColor(m[@"sender"]);
		cell.nameLabel.frame = CGRectMake(x, y, contentW, 17);
		cell.nameLine.frame = CGRectMake(x, y + 19, contentW, 1);
		y += 22;
	}
	NSDictionary *quote = QuoteOf(m);
	if (quote) {
		BOOL quoteMine = [quote[@"fromMe"] boolValue];
		UIColor *qc = quoteMine ? WAColor(0x35A24A) : WANameColor(quote[@"sender"]);
		cell.quoteBox.hidden = cell.quoteBar.hidden = cell.quoteName.hidden = cell.quoteText.hidden = NO;
		cell.quoteBox.frame = CGRectMake(x - 3, y, contentW + 6, kQuoteHeight);
		cell.quoteBar.backgroundColor = qc;
		cell.quoteName.text = QuoteName(quote);
		cell.quoteName.textColor = qc;
		cell.quoteName.frame = CGRectMake(9, 3, contentW - 8, 16);
		cell.quoteText.text = QuoteLine(quote);
		cell.quoteText.frame = CGRectMake(9, 19, contentW - 8, 17);
		y += kQuoteHeight + 4;
	}
	if (IsMedia(m)) {
		cell.photo.hidden = NO;
		cell.photo.frame = CGRectMake(x - 3, y, contentW + 6, kImageHeight);
		cell.photo.image = [self imageFor:m];
		if (IsVideo(m)) {
			CGRect p = cell.photo.frame;
			BOOL loading = [_loadingVideo isEqual:m[@"seq"]];
			cell.videoPlay.hidden = cell.videoBar.hidden = cell.videoLabel.hidden = NO;
			cell.videoPlay.alpha = loading ? 0.4 : 1;
			cell.videoPlay.frame = CGRectMake(CGRectGetMidX(p) - 22, CGRectGetMidY(p) - 22, 44, 44);
			cell.videoBar.frame = CGRectMake(p.origin.x, CGRectGetMaxY(p) - 18, p.size.width, 18);
			NSInteger secs = [m[@"secs"] integerValue];
			cell.videoLabel.text = loading ? @"Loading video…" : [NSString stringWithFormat:@"▶  %@", WADuration(secs)];
			cell.videoLabel.frame = CGRectMake(p.origin.x + 6, CGRectGetMaxY(p) - 17, p.size.width - 12, 16);
			cell.videoLabel.textAlignment = loading ? NSTextAlignmentCenter : NSTextAlignmentRight;
		}
		y += kImageHeight + 4;
	}
	if (IsVoice(m)) {
		[self layoutVoice:m cell:cell x:x y:y width:contentW mine:mine row:indexPath.row];
		y += kVoiceHeight;
	}
	NSString *body = BodyText(m);
	if (body.length) {
		cell.bodyLabel.hidden = NO;
		cell.bodyLabel.text = body;
		cell.bodyLabel.textColor = [m[@"kind"] isEqualToString:@"text"] || IsMedia(m) ? [UIColor blackColor] : WAColor(0x555555);
		cell.bodyLabel.frame = CGRectMake(x, y, textSize.width, textSize.height);
	}

	NSArray *reactions = ReactionsOf(m);
	if (reactions) {
		NSString *rt = ReactionsText(reactions);
		CGFloat rw = ceilf([rt sizeWithFont:cell.reactButton.titleLabel.font].width) + 16;
		cell.reactButton.hidden = NO;
		[cell.reactButton setTitle:rt forState:UIControlStateNormal];
		cell.reactButton.frame = CGRectMake(mine ? CGRectGetMaxX(bubble) - 24 - rw : bubble.origin.x + 22,
			CGRectGetMaxY(bubble) - 5, rw, 20);
		cell.reactButton.tag = indexPath.row;
		[cell.reactButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
		[cell.reactButton addTarget:self action:@selector(reactionsTapped:) forControlEvents:UIControlEventTouchUpInside];
	}
	[self prefetch:m];

	// time pill + ticks
	NSString *time = WAPrefBool(WAPrefMessageTimestamp) ? [self timeText:m] : @"";
	UIImage *tick = nil;
	if (mine) {
		int status = [m[@"status"] intValue];
		// groups: the first reader already sends read, whatsapp waits for everyone
		if (status >= 3 && ![_jid hasSuffix:@"@g.us"]) tick = WAReadTick();
		else tick = WAImg(status == 0 ? @"GrayClockIcon" : (status >= 2 ? @"mark_d" : @"mark_s"));
	}
	CGFloat timeW = ceilf([time sizeWithFont:TimeFont()].width);
	if (!time.length && !tick) return cell;
	CGFloat pillW = timeW + 12 + (tick ? 17 : 0) - (time.length ? 0 : 6);
	CGFloat pillX = mine ? bubble.origin.x - pillW + 4 : CGRectGetMaxX(bubble) - 4;
	CGFloat pillY = CGRectGetMaxY(bubble) - 21;
	cell.timePill.hidden = cell.timeLabel.hidden = NO;
	cell.timePill.frame = CGRectMake(pillX, pillY, pillW, 16);
	cell.timeLabel.text = time;
	cell.timeLabel.frame = CGRectMake(pillX + 6, pillY + 1, timeW, 14);
	if (tick) {
		cell.tick.hidden = NO;
		cell.tick.image = tick;
		cell.tick.frame = CGRectMake(pillX + (time.length ? 8 + timeW : 3), pillY + 1, 16, 14);
	}
	return cell;
}

#pragma mark - Voice messages

- (void)layoutVoice:(NSDictionary *)m cell:(WAMessageCell *)cell x:(CGFloat)x y:(CGFloat)y width:(CGFloat)w
	mine:(BOOL)mine row:(NSInteger)row {
	BOOL current = [_playingSeq isEqual:m[@"seq"]];
	BOOL playing = current && _player.playing;
	cell.playButton.hidden = cell.slider.hidden = cell.micIcon.hidden = cell.durationLabel.hidden = NO;
	UIImage *play = WAImg(playing ? @"Pause" : @"Play");
	[cell.playButton setImage:play forState:UIControlStateNormal];
	[cell.playButton setImage:WAImg(playing ? @"PausePressed" : @"PlayPressed") forState:UIControlStateHighlighted];
	[cell.playButton setTitle:play ? nil : (playing ? @"❚❚" : @"▶") forState:UIControlStateNormal];
	[cell.playButton setTitleColor:WAColor(0x555555) forState:UIControlStateNormal];
	if (current && _loadingVoice) {
		[cell.playButton setImage:nil forState:UIControlStateNormal];
		[cell.playButton setTitle:@"…" forState:UIControlStateNormal];
	}
	cell.playButton.frame = CGRectMake(x - 4, y + 3, 34, 34);
	cell.playButton.tag = row;
	[cell.playButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
	[cell.playButton addTarget:self action:@selector(playTapped:) forControlEvents:UIControlEventTouchUpInside];

	cell.slider.frame = CGRectMake(x + 32, y + 4, w - 32 - 22, 23);
	cell.slider.tag = row;
	cell.slider.minimumValue = 0;
	cell.slider.maximumValue = 1;
	cell.slider.value = current && _player.duration > 0 ? _player.currentTime / _player.duration : 0;
	[cell.slider removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
	[cell.slider addTarget:self action:@selector(seek:) forControlEvents:UIControlEventValueChanged];

	cell.micIcon.image = WAImg(mine ? @"MicOutgoing" : @"MicIncoming");
	cell.micIcon.frame = CGRectMake(x + w - 16, y + 6, 16, 20);
	NSInteger secs = [m[@"secs"] integerValue];
	cell.durationLabel.text = current && _player ? WADuration((NSInteger)_player.currentTime) : (secs ? WADuration(secs) : @"");
	cell.durationLabel.frame = CGRectMake(x + 34, y + 27, 60, 13);
}

- (NSDictionary *)messageAtRow:(NSInteger)row {
	if (row < 0 || row >= (NSInteger)_rows.count) return nil;
	id o = _rows[row];
	return [o isKindOfClass:[NSDictionary class]] ? o : nil;
}

- (void)seek:(UISlider *)slider {
	NSDictionary *m = [self messageAtRow:slider.tag];
	if (_player && [_playingSeq isEqual:m[@"seq"]]) _player.currentTime = slider.value * _player.duration;
}

- (void)playTapped:(UIButton *)button {
	NSDictionary *m = [self messageAtRow:button.tag];
	NSNumber *seq = m[@"seq"];
	if (!seq || [seq longLongValue] <= 0) return; // sending
	if ([_playingSeq isEqual:seq] && _player) {
		if (_player.playing) [_player pause]; else [_player play];
		[self reloadSeq:seq];
		return;
	}
	[self stopVoice];
	_playingSeq = seq;
	NSData *cached = [_voiceData objectForKey:seq];
	if (cached) {
		[self playData:cached];
		return;
	}
	_loadingVoice = YES;
	[self reloadSeq:seq];
	NSURLRequest *req = [[WAClient shared] voiceRequestForSeq:[seq longLongValue]];
	[[WAClient shared] load:req completion:^(NSData *data, NSInteger code, NSError *error) {
			if (![self->_playingSeq isEqual:seq]) return;
			self->_loadingVoice = NO;
			if (error || code != 200 || !data.length) {
				self->_playingSeq = nil;
				[self reloadSeq:seq];
				[[[UIAlertView alloc] initWithTitle:@"Audio" message:@"Could not be loaded." delegate:nil
					cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
				return;
			}
			[self->_voiceData setObject:data forKey:seq];
			[self playData:data];
		}];
}

- (void)playData:(NSData *)data {
	AVAudioSession *session = [AVAudioSession sharedInstance];
	[session setCategory:AVAudioSessionCategoryPlayback error:NULL];
	[session setActive:YES error:NULL];
	_player = [[AVAudioPlayer alloc] initWithData:data error:NULL];
	_player.delegate = (id<AVAudioPlayerDelegate>)self;
	[_player play];
	[_progressTimer invalidate];
	_progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(progressTick)
		userInfo:nil repeats:YES];
	[self reloadSeq:_playingSeq];
}

- (void)progressTick {
	NSIndexPath *ip = _playingSeq ? [self indexPathForSeq:_playingSeq] : nil;
	WAMessageCell *cell = ip ? (WAMessageCell *)[_table cellForRowAtIndexPath:ip] : nil;
	if (!cell || !_player || cell.slider.tracking) return;
	cell.slider.value = _player.duration > 0 ? _player.currentTime / _player.duration : 0;
	cell.durationLabel.text = WADuration((NSInteger)_player.currentTime);
}

- (void)stopVoice {
	NSNumber *old = _playingSeq;
	[_progressTimer invalidate];
	_progressTimer = nil;
	_player.delegate = nil;
	[_player stop];
	_player = nil;
	_playingSeq = nil;
	_loadingVoice = NO;
	[self reloadSeq:old];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
	[self stopVoice];
}

#pragma mark - Recording (hold the microphone, slide left to cancel)

- (NSString *)recordingPath {
	return [NSTemporaryDirectory() stringByAppendingPathComponent:@"wa4s-recording.m4a"];
}

- (void)micDown:(UIButton *)button withEvent:(UIEvent *)event {
	_recordStartX = [[event.allTouches anyObject] locationInView:_bar].x;
	_recordCancelled = NO;
	[self startRecording];
}

- (void)micMove:(UIButton *)button withEvent:(UIEvent *)event {
	if (!_recorder) return;
	CGFloat dx = MIN(0, [[event.allTouches anyObject] locationInView:_bar].x - _recordStartX);
	CGRect f = _slideLabel.frame;
	f.origin.x = 90 + dx;
	_slideLabel.frame = f;
	_slideLabel.alpha = MAX(0.2, 1 + dx / 160);
	if (dx < -120 && !_recordCancelled) {
		_recordCancelled = YES;
		[self finishRecording:NO];
	}
}

- (void)micUp:(UIButton *)button withEvent:(UIEvent *)event {
	if (_recorder) [self finishRecording:!_recordCancelled];
}

- (void)micCancel {
	if (_recorder) [self finishRecording:NO];
}

- (void)startRecording {
	[self stopVoice];
	[_field resignFirstResponder];
	AVAudioSession *session = [AVAudioSession sharedInstance];
	[session setCategory:AVAudioSessionCategoryPlayAndRecord error:NULL];
	[session setActive:YES error:NULL];
	NSDictionary *settings = @{AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @16000.0,
		AVNumberOfChannelsKey: @1, AVEncoderBitRateKey: @32000, AVEncoderAudioQualityKey: @(AVAudioQualityMedium)};
	NSError *error = nil;
	_recorder = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:[self recordingPath]] settings:settings error:&error];
	if (!_recorder || ![_recorder record]) {
		_recorder = nil;
		[[[UIAlertView alloc] initWithTitle:@"Record" message:error.localizedDescription ?: @"Microphone not available."
			delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
		return;
	}
	_recordView.hidden = NO;
	CGRect f = _slideLabel.frame;
	f.origin.x = 90;
	_slideLabel.frame = f;
	_slideLabel.alpha = 1;
	[self recordTick];
	_recordTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(recordTick) userInfo:nil repeats:YES];
}

- (void)recordTick {
	_recordTime.text = WADuration((NSInteger)_recorder.currentTime);
	_recordDot.alpha = _recordDot.alpha > 0.5 ? 0.25 : 1;
}

- (void)finishRecording:(BOOL)send {
	NSTimeInterval length = _recorder.currentTime;
	[_recordTimer invalidate];
	_recordTimer = nil;
	[_recorder stop];
	_recorder = nil;
	_recordView.hidden = YES;
	[[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:NULL];
	NSData *data = send && length >= 1 ? [NSData dataWithContentsOfFile:[self recordingPath]] : nil;
	[[NSFileManager defaultManager] removeItemAtPath:[self recordingPath] error:NULL];
	if (!data.length) return;
	NSString *jid = _jid;
	[self insertTemp:[self tempMessage:@"audio" text:@"" secs:(NSInteger)round(length)] request:^(WAJSONBlock done) {
		[[WAClient shared] post:@"/api/sendvoice" params:@{@"chat": jid} data:data contentType:@"audio/mp4" completion:done];
	}];
}

#pragma mark - Sending photos

- (void)attachTapped {
	[_field resignFirstResponder];
	UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:nil
		destructiveButtonTitle:nil otherButtonTitles:nil];
	if ([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
		[sheet addButtonWithTitle:@"Take Photo or Video"];
	}
	[sheet addButtonWithTitle:@"Choose Existing"];
	sheet.cancelButtonIndex = [sheet addButtonWithTitle:@"Cancel"];
	[sheet showInView:self.view];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
	if (index == sheet.cancelButtonIndex) return;
	NSString *title = [sheet buttonTitleAtIndex:index];
	if ([title isEqualToString:@"Remove Attachment"]) {
		if (_removeIndex >= 0 && _removeIndex < (NSInteger)_pending.count) [_pending removeObjectAtIndex:_removeIndex];
		[self updateAttachmentsBar];
		return;
	}
	if ([title isEqualToString:@"Call Back"]) {
		[self startCall];
		return;
	}
	if ([title isEqualToString:@"Voice Call"] || [title isEqualToString:@"Video Call"]) {
		[[WACall shared] callJID:_jid name:_chat[@"name"] video:[title isEqualToString:@"Video Call"]];
		return;
	}
	UIImagePickerController *picker = [[UIImagePickerController alloc] init];
	picker.sourceType = [title isEqualToString:@"Take Photo or Video"] ? UIImagePickerControllerSourceTypeCamera
		: UIImagePickerControllerSourceTypePhotoLibrary;
	picker.mediaTypes = @[(__bridge NSString *)kUTTypeImage, (__bridge NSString *)kUTTypeMovie];
	picker.videoQuality = UIImagePickerControllerQualityTypeMedium;
	picker.videoMaximumDuration = 180;
	picker.delegate = self;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
	[picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
	[picker dismissViewControllerAnimated:YES completion:nil];
	if ([info[UIImagePickerControllerMediaType] isEqualToString:(__bridge NSString *)kUTTypeMovie]) {
		[self sendVideoAt:info[UIImagePickerControllerMediaURL]];
		return;
	}
	UIImage *image = info[UIImagePickerControllerOriginalImage];
	if (!image) return;
	[self addPendingImage:image];
}

- (void)addPendingImage:(UIImage *)image {
	// max 1280px, jpeg
	CGFloat f = MIN(1, 1280 / MAX(image.size.width, image.size.height));
	CGSize s = CGSizeMake(roundf(image.size.width * f), roundf(image.size.height * f));
	UIGraphicsBeginImageContextWithOptions(s, YES, 1);
	[image drawInRect:CGRectMake(0, 0, s.width, s.height)];
	UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	NSData *jpeg = UIImageJPEGRepresentation(scaled, 0.7);
	if (!jpeg.length) return;
	[_pending addObject:@{@"kind": @"image", @"data": jpeg, @"preview": [self previewOf:scaled]}];
	[self updateAttachmentsBar];
}

- (void)sendImage:(NSData *)jpeg preview:(UIImage *)preview quote:(NSDictionary *)quote {
	NSDictionary *temp = [self tempMessage:@"image" text:@"" secs:0 quote:quote];
	[_images setObject:preview forKey:temp[@"seq"]];
	NSString *jid = _jid;
	NSDictionary *params = quote ? @{@"chat": jid, @"quote": quote[@"id"]} : @{@"chat": jid};
	[self insertTemp:temp request:^(WAJSONBlock done) {
		[[WAClient shared] post:@"/api/sendimage" params:params data:jpeg contentType:@"image/jpeg"
			completion:^(id json, NSError *error) {
				// reuse the image we have
				if (!error && json[@"seq"]) [self->_images setObject:preview forKey:json[@"seq"]];
				done(json, error);
			}];
	}];
}

- (void)sendVideoAt:(NSURL *)url {
	NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
	if (!data.length) return;
	AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
	NSInteger secs = (NSInteger)round(CMTimeGetSeconds(asset.duration));
	AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
	gen.appliesPreferredTrackTransform = YES;
	CGImageRef frame = [gen copyCGImageAtTime:CMTimeMakeWithSeconds(0.5, 600) actualTime:NULL error:NULL];
	UIImage *preview = nil;
	if (frame) {
		preview = [self previewOf:[UIImage imageWithCGImage:frame]];
		CGImageRelease(frame);
	}
	NSMutableDictionary *item = [@{@"kind": @"video", @"data": data, @"secs": @(secs)} mutableCopy];
	if (preview) item[@"preview"] = preview;
	[_pending addObject:item];
	[self updateAttachmentsBar];
}

- (void)sendVideo:(NSData *)data preview:(UIImage *)preview secs:(NSInteger)secs quote:(NSDictionary *)quote {
	NSDictionary *temp = [self tempMessage:@"video" text:@"" secs:secs quote:quote];
	if (preview) [_images setObject:preview forKey:temp[@"seq"]];
	NSString *jid = _jid;
	NSDictionary *params = quote ? @{@"chat": jid, @"quote": quote[@"id"]} : @{@"chat": jid};
	[self insertTemp:temp request:^(WAJSONBlock done) {
		[[WAClient shared] post:@"/api/sendvideo" params:params data:data contentType:@"video/quicktime"
			completion:^(id json, NSError *error) {
				if (!error && json[@"seq"] && preview) [self->_images setObject:preview forKey:json[@"seq"]];
				done(json, error);
			}];
	}];
}

#pragma mark - Opening photos and videos

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	NSDictionary *m = [self messageAtRow:indexPath.row];
	if (!m || [m[@"seq"] longLongValue] <= 0) return;
	if (IsCall(m) && !_group) {
		[_field resignFirstResponder];
		UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:nil
			destructiveButtonTitle:nil otherButtonTitles:@"Call Back", nil];
		sheet.cancelButtonIndex = [sheet addButtonWithTitle:@"Cancel"];
		[sheet showInView:self.view];
		return;
	}
	if (IsVideo(m)) [self playVideo:m];
	else if (IsMedia(m)) [self showPhoto:m];
	else if (QuoteOf(m)) {
		NSIndexPath *ip = [self indexPathForMessageID:QuoteOf(m)[@"id"]];
		if (ip) [_table scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
	}
}

#pragma mark - Swipe: right to reply, left to react

// real message row (has a seq)
- (NSDictionary *)swipeableMessageAt:(NSIndexPath *)ip {
	NSDictionary *m = ip ? [self messageAtRow:ip.row] : nil;
	if (!m || IsCall(m) || IsSystem(m) || [m[@"seq"] longLongValue] <= 0) return nil;
	return m;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
	if (![g isKindOfClass:[UIPanGestureRecognizer class]] || g.view != _table) return YES;
	// use translation, velocity is often 0 on the 3gs
	CGPoint t = [(UIPanGestureRecognizer *)g translationInView:_table];
	if (t.x == 0 && t.y == 0) t = [(UIPanGestureRecognizer *)g velocityInView:_table];
	if (fabs(t.x) < fabs(t.y) * 1.2) return NO; // vertical = table scroll
	return [self swipeableMessageAt:[_table indexPathForRowAtPoint:[g locationInView:_table]]] != nil;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
	return YES;
}

// react icon
- (UIImage *)reactGlyph {
	UIGraphicsBeginImageContextWithOptions(CGSizeMake(30, 30), NO, 0);
	[WAColor(0x8C949E) setFill];
	[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(2, 2, 26, 26)] fill];
	[[UIColor whiteColor] set];
	[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(10, 10, 3.5, 4.5)] fill];
	[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(16.5, 10, 3.5, 4.5)] fill];
	UIBezierPath *smile = [UIBezierPath bezierPathWithArcCenter:CGPointMake(15, 15) radius:7 startAngle:0.2 * M_PI
		endAngle:0.8 * M_PI clockwise:YES];
	smile.lineWidth = 2;
	smile.lineCapStyle = kCGLineCapRound;
	[smile stroke];
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

- (void)swiped:(UIPanGestureRecognizer *)pan {
	if (pan.state == UIGestureRecognizerStateBegan) {
		_swipeRow = [_table indexPathForRowAtPoint:[pan locationInView:_table]];
		_swipePassed = NO;
		// precompute everything, 3gs lagged otherwise
		if (!_replyGlyph) _replyGlyph = [self quoteGlyph];
		if (!_reactGlyph) _reactGlyph = [self reactGlyph];
		CGRect r = [_table rectForRowAtIndexPath:_swipeRow];
		_swipeMid = r.origin.y + ([self bubbleSizeFor:[self messageAtRow:_swipeRow.row] textSize:NULL].height + 4) / 2;
		// snapshot the bubble once
		UITableViewCell *cell = [_table cellForRowAtIndexPath:_swipeRow];
		cell.contentView.layer.rasterizationScale = [UIScreen mainScreen].scale;
		cell.contentView.layer.shouldRasterize = YES;
		// block table scrolling while swiping
		_table.scrollEnabled = NO;
		_table.scrollEnabled = YES;
		return;
	}
	WAMessageCell *cell = _swipeRow ? (WAMessageCell *)[_table cellForRowAtIndexPath:_swipeRow] : nil;
	CGFloat dx = [pan translationInView:_table].x;
	// rubber band past the trigger
	CGFloat shown = fabs(dx) <= kSwipeTrigger ? dx : (dx > 0 ? 1 : -1) * (kSwipeTrigger + (fabs(dx) - kSwipeTrigger) * 0.3);
	shown = MAX(-110, MIN(110, shown));
	if (pan.state == UIGestureRecognizerStateChanged) {
		if (!cell) return;
		cell.contentView.transform = CGAffineTransformMakeTranslation(shown, 0);
		BOOL reply = dx > 0;
		if (!_swipeIcon) {
			_swipeIcon = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
			_swipeIcon.contentMode = UIViewContentModeCenter;
			[_table insertSubview:_swipeIcon atIndex:0];
		}
		UIImage *glyph = reply ? _replyGlyph : _reactGlyph;
		if (_swipeIcon.image != glyph) _swipeIcon.image = glyph;
		CGFloat bubbleMid = _swipeMid;
		CGFloat progress = MIN(1, fabs(shown) / kSwipeTrigger);
		CGFloat inset = MIN(24, fabs(shown) / 2 + 2);
		_swipeIcon.center = CGPointMake(reply ? inset : _table.bounds.size.width - inset, bubbleMid);
		_swipeIcon.alpha = progress;
		if (!_swipePassed) _swipeIcon.transform = CGAffineTransformMakeScale(0.4 + 0.6 * progress, 0.4 + 0.6 * progress);
		BOOL passed = fabs(dx) >= kSwipeTrigger;
		if (passed != _swipePassed) {
			_swipePassed = passed;
			// small pop at the trigger
			if (passed) {
				_swipeIcon.transform = CGAffineTransformMakeScale(1.3, 1.3);
				[UIView animateWithDuration:0.15 animations:^{ self->_swipeIcon.transform = CGAffineTransformIdentity; }];
			}
		}
		return;
	}
	// snap back, then reply/react. also check the final position, slow devices skip moves
	NSDictionary *m = [self swipeableMessageAt:_swipeRow];
	CGFloat vx = [pan velocityInView:_table].x;
	BOOL far = _swipePassed || fabs(dx) >= kSwipeTrigger || (fabs(dx) >= kSwipeTrigger / 2 && fabs(vx) > 400 && vx * dx > 0);
	// ios 4 reports fast flicks as cancelled
	BOOL go = (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) && far && m;
	BOOL reply = dx > 0;
	NSIndexPath *ip = _swipeRow;
	UIImageView *icon = _swipeIcon;
	_swipeIcon = nil;
	_swipeRow = nil;
	[UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
		cell.contentView.transform = CGAffineTransformIdentity;
		icon.alpha = 0;
	} completion:^(BOOL finished) {
		[icon removeFromSuperview];
		cell.contentView.layer.shouldRasterize = NO;
	}];
	if (!go) return;
	if (reply) {
		_quote = m;
		[self updateAttachmentsBar];
		[_field becomeFirstResponder];
	} else {
		[_field resignFirstResponder];
		[self showReactBar:m row:ip];
	}
}

#pragma mark - Long press: Reply, React, Copy

- (BOOL)canBecomeFirstResponder {
	return YES;
}

- (void)pressed:(UILongPressGestureRecognizer *)press {
	if (press.state != UIGestureRecognizerStateBegan) return;
	NSIndexPath *ip = [_table indexPathForRowAtPoint:[press locationInView:_table]];
	NSDictionary *m = ip ? [self messageAtRow:ip.row] : nil;
	if (!m || IsCall(m) || IsSystem(m) || [m[@"seq"] longLongValue] <= 0) return;
	_menuMessage = m;
	_menuRow = ip;
	[self becomeFirstResponder];
	BOOL mine = [m[@"fromMe"] boolValue];
	CGSize size = [self bubbleSizeFor:m textSize:NULL];
	CGRect cell = [_table rectForRowAtIndexPath:ip];
	CGFloat width = _table.bounds.size.width;
	CGRect bubble = CGRectMake(mine ? width - size.width - 3 : 3, cell.origin.y + 2, size.width, size.height);
	UIMenuController *menu = [UIMenuController sharedMenuController];
	menu.menuItems = @[[[UIMenuItem alloc] initWithTitle:@"Reply" action:@selector(replyToMessage:)],
		[[UIMenuItem alloc] initWithTitle:@"React" action:@selector(reactToMessage:)]];
	[menu setTargetRect:bubble inView:_table];
	[menu setMenuVisible:YES animated:YES];
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
	if (!_menuMessage) return NO;
	if (action == @selector(replyToMessage:) || action == @selector(reactToMessage:)) return YES;
	if (action == @selector(copy:)) return [_menuMessage[@"text"] length] > 0;
	return NO;
}

- (void)copy:(id)sender {
	if ([_menuMessage[@"text"] length]) [UIPasteboard generalPasteboard].string = _menuMessage[@"text"];
	_menuMessage = nil;
}

- (void)replyToMessage:(id)sender {
	_quote = _menuMessage;
	_menuMessage = nil;
	[self updateAttachmentsBar];
	[_field becomeFirstResponder];
}

- (void)reactToMessage:(id)sender {
	NSDictionary *m = _menuMessage;
	_menuMessage = nil;
	if (!m) return;
	[_field resignFirstResponder];
	[self showReactBar:m row:_menuRow];
}

- (void)showReactBar:(NSDictionary *)m row:(NSIndexPath *)ip {
	UIView *top = self.navigationController.view ?: self.view;
	BOOL mine = [m[@"fromMe"] boolValue];
	CGSize size = [self bubbleSizeFor:m textSize:NULL];
	CGRect cell = [_table rectForRowAtIndexPath:ip];
	CGFloat width = _table.bounds.size.width;
	CGRect bubble = CGRectMake(mine ? width - size.width - 3 : 3, cell.origin.y + 2, size.width, size.height);
	[WAReactBar showForMessage:m chat:_jid bubble:[_table convertRect:bubble toView:top] inView:top];
}

- (void)reactionsTapped:(UIButton *)b {
	NSDictionary *m = [self messageAtRow:b.tag];
	if (!ReactionsOf(m)) return;
	[_field resignFirstResponder];
	[self presentViewController:WAModal([[WAReactionsViewController alloc] initWithChat:_jid message:m], NO)
		animated:YES completion:nil];
}

#pragma mark - Auto-Download

// auto-download voice/video, one at a time
- (void)prefetch:(NSDictionary *)m {
	NSNumber *seq = m[@"seq"];
	if ([seq longLongValue] <= 0 || _prefetching.count) return;
	if (IsVoice(m) && ![_voiceData objectForKey:seq] && WAAutoDownload(WAPrefAutoAudio)) {
		[_prefetching addObject:seq];
		[[WAClient shared] load:[[WAClient shared] voiceRequestForSeq:[seq longLongValue]]
			completion:^(NSData *data, NSInteger code, NSError *error) {
				[self->_prefetching removeObject:seq];
				if (code == 200 && data.length) [self->_voiceData setObject:data forKey:seq];
			}];
	} else if (IsVideo(m) && ![m[@"fromMe"] boolValue] && ![self cachedVideoFor:seq] && !_loadingVideo
		&& WAAutoDownload(WAPrefAutoVideos)) {
		BOOL small = WAOptimizeVideoNow();
		[_prefetching addObject:seq];
		[[WAClient shared] load:[[WAClient shared] videoRequestForSeq:[seq longLongValue] optimized:small]
			completion:^(NSData *data, NSInteger code, NSError *error) {
				[self->_prefetching removeObject:seq];
				if (code == 200 && data.length) [data writeToFile:[self videoPathFor:seq small:small] atomically:YES];
			}];
	}
}

- (NSString *)videoPathFor:(NSNumber *)seq small:(BOOL)small {
	return [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"wa4s-video-%@%@.mp4", seq,
		small ? @"-small" : @""]];
}

// full video or the optimized one
- (NSString *)cachedVideoFor:(NSNumber *)seq {
	NSFileManager *fm = [NSFileManager defaultManager];
	for (NSNumber *small in @[@NO, @YES]) {
		NSString *path = [self videoPathFor:seq small:[small boolValue]];
		if ([fm fileExistsAtPath:path]) return path;
	}
	return nil;
}

- (void)playVideo:(NSDictionary *)m {
	NSNumber *seq = m[@"seq"];
	NSString *cached = [self cachedVideoFor:seq];
	if (cached) {
		[self presentVideoAt:cached];
		return;
	}
	if (_loadingVideo) return;
	_loadingVideo = seq;
	[self reloadSeq:seq];
	// optimize video setting
	BOOL small = WAOptimizeVideoNow();
	NSString *path = [self videoPathFor:seq small:small];
	[[WAClient shared] load:[[WAClient shared] videoRequestForSeq:[seq longLongValue] optimized:small]
		completion:^(NSData *data, NSInteger status, NSError *error) {
			self->_loadingVideo = nil;
			[self reloadSeq:seq];
			if (status != 200 || !data.length || ![data writeToFile:path atomically:YES]) {
				[[[UIAlertView alloc] initWithTitle:@"Video" message:@"Could not be loaded." delegate:nil
					cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
				return;
			}
			[self presentVideoAt:path];
		}];
}

- (void)presentVideoAt:(NSString *)path {
	[self stopVoice];
	[[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:NULL];
	MPMoviePlayerViewController *player = [[MPMoviePlayerViewController alloc] initWithContentURL:[NSURL fileURLWithPath:path]];
	[self presentMoviePlayerViewControllerAnimated:player];
}

- (void)showPhoto:(NSDictionary *)m {
	UIViewController *vc = [[UIViewController alloc] init];
	vc.view.backgroundColor = [UIColor blackColor];
	UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:vc.view.bounds];
	scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	scroll.maximumZoomScale = 4;
	scroll.delegate = self;
	UIImageView *iv = [[UIImageView alloc] initWithFrame:scroll.bounds];
	iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	iv.contentMode = UIViewContentModeScaleAspectFit;
	iv.image = [_images objectForKey:m[@"seq"]];
	iv.tag = 77;
	[scroll addSubview:iv];
	[vc.view addSubview:scroll];
	UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closePhoto)];
	[scroll addGestureRecognizer:tap];
	vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
	[self presentViewController:vc animated:YES completion:nil];
	[[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationFade];
	[[WAClient shared] load:[[WAClient shared] mediaRequestForSeq:[m[@"seq"] longLongValue]]
		completion:^(NSData *data, NSInteger status, NSError *error) {
			UIImage *full = status == 200 ? [UIImage imageWithData:data] : nil;
			if (full) iv.image = full;
		}];
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
	return [scrollView viewWithTag:77];
}

- (void)closePhoto {
	[[UIApplication sharedApplication] setStatusBarHidden:NO withAnimation:UIStatusBarAnimationFade];
	[self dismissViewControllerAnimated:YES completion:nil];
}

// cache sized images, smoother scrolling on the 4s
- (UIImage *)previewOf:(UIImage *)full {
	CGSize target = CGSizeMake(kImageWidth + 6, kImageHeight);
	CGFloat f = MAX(target.width / full.size.width, target.height / full.size.height);
	CGSize s = CGSizeMake(ceilf(full.size.width * f), ceilf(full.size.height * f));
	UIGraphicsBeginImageContextWithOptions(s, YES, [UIScreen mainScreen].scale);
	[full drawInRect:CGRectMake(0, 0, s.width, s.height)];
	UIImage *small = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return small;
}

#pragma mark - Pictures

// save to camera roll once
- (void)saveIncoming:(UIImage *)img seq:(NSNumber *)seq {
	if (!WAPrefBool(WAPrefSaveIncomingMedia)) return;
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	NSMutableArray *saved = [[d arrayForKey:@"savedMedia"] mutableCopy] ?: [NSMutableArray array];
	if ([saved containsObject:seq]) return;
	[saved addObject:seq];
	if (saved.count > 2000) [saved removeObjectsInRange:NSMakeRange(0, saved.count - 2000)];
	[d setObject:saved forKey:@"savedMedia"];
	UIImageWriteToSavedPhotosAlbum(img, nil, NULL, NULL);
}

- (UIImage *)imageFor:(NSDictionary *)m {
	NSNumber *seq = m[@"seq"];
	UIImage *img = [_images objectForKey:seq];
	if (img || [_loadingImages containsObject:seq] || [seq longLongValue] <= 0) return img;
	[_loadingImages addObject:seq];
	// no auto-download: show the thumb, full pic on tap
	BOOL incoming = ![m[@"fromMe"] boolValue];
	BOOL full = !incoming || WAAutoDownload(WAPrefAutoPhotos);
	NSURLRequest *req = IsVideo(m) ? [[WAClient shared] mediaRequestForSeq:[seq longLongValue] format:@"poster"]
		: [[WAClient shared] mediaRequestForSeq:[seq longLongValue] format:full ? nil : @"thumb"];
	[[WAClient shared] load:req completion:^(NSData *data, NSInteger code, NSError *error) {
			[self->_loadingImages removeObject:seq];
			UIImage *img = data.length ? [UIImage imageWithData:data] : nil;
			if (!img) return;
			if (full && incoming && !IsVideo(m)) [self saveIncoming:img seq:seq];
			[self->_images setObject:[self previewOf:img] forKey:seq];
			[self reloadSeq:seq];
		}];
	return nil;
}

@end
