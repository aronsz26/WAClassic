#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <dlfcn.h>
#import "WAReactions.h"
#import "WAClient.h"
#import "WAAssets.h"
#import "WABubbles.h"
#import "WAPrefs.h"
#import "WAUtil.h"

UIViewController *WAModal(UIViewController *vc, BOOL black) {
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
	if (black) nav.navigationBar.barStyle = UIBarStyleBlack;
	return nav;
}

static NSString *ShortText(NSDictionary *m) {
	NSString *text = m[@"text"];
	if ([m[@"kind"] isEqualToString:@"text"] || text.length) return text;
	return WAKindLabel(m[@"kind"]);
}

#pragma mark - React

// no public api for the emoji keyboard, UIKeyboardImpl works on ios 4-6
static id KeyboardImpl(void) {
	Class impl = NSClassFromString(@"UIKeyboardImpl");
	SEL active = NSSelectorFromString(@"activeInstance"), shared = NSSelectorFromString(@"sharedInstance");
	if ([impl respondsToSelector:active]) return ((id (*)(id, SEL))objc_msgSend)(impl, active);
	if ([impl respondsToSelector:shared]) return ((id (*)(id, SEL))objc_msgSend)(impl, shared);
	return nil;
}

static NSString *CurrentInputMode(void) {
	NSString *(*get)(void) = (NSString *(*)(void))dlsym(RTLD_DEFAULT, "UIKeyboardGetCurrentInputMode");
	return get ? get() : nil;
}

static void SetInputMode(NSString *mode) {
	id kb = KeyboardImpl();
	SEL set = NSSelectorFromString(@"setInputMode:");
	if (!mode || ![kb respondsToSelector:set]) return;
	@try {
		((void (*)(id, SEL, id))objc_msgSend)(kb, set, mode);
	} @catch (id e) {
		WALog(@"react: input mode %@ failed", mode);
	}
}

// quick reactions like whatsapp today, + = any emoji
static NSString *const kQuick[] = {@"\U0001F44D", @"❤️", @"\U0001F602", @"\U0001F62E", @"\U0001F622", @"\U0001F64F"};
static const int kQuickCount = 6;
static const CGFloat kItem = 40, kPillH = 48, kPad = 6;

// 1F62E is unicode 6.1, stock ios 6 font doesn't have it -> show 1F632
static NSString *QuickLabel(NSString *e) {
	if ([e isEqualToString:@"\U0001F62E"]) return @"\U0001F632";
	return WAEmojiForDisplay(e);
}

// gray circle with a plus
static UIImage *PlusImage(void) {
	UIGraphicsBeginImageContextWithOptions(CGSizeMake(32, 32), NO, 0);
	[WAColor(0xDCE0E6) setFill];
	[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, 30, 30)] fill];
	[WAColor(0x7B838D) setFill];
	[[UIBezierPath bezierPathWithRoundedRect:CGRectMake(9, 15, 14, 2.5) cornerRadius:1.2] fill];
	[[UIBezierPath bezierPathWithRoundedRect:CGRectMake(14.75, 9, 2.5, 14) cornerRadius:1.2] fill];
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

@implementation WAReactBar {
	NSString *_jid, *_mine, *_previousMode;
	NSDictionary *_message;
	UIView *_pill;
	UITextField *_field;
	CGRect _bubble;
	BOOL _done;
}

+ (void)showForMessage:(NSDictionary *)message chat:(NSString *)jid bubble:(CGRect)bubble inView:(UIView *)view {
	if (!view) return;
	WAReactBar *bar = [[WAReactBar alloc] initWithFrame:view.bounds];
	bar->_jid = [jid copy];
	bar->_message = message;
	bar->_bubble = bubble;
	for (NSDictionary *r in message[@"reactions"]) {
		if ([r[@"fromMe"] boolValue]) bar->_mine = r[@"emoji"];
	}
	[bar build];
	[view addSubview:bar];
	[bar popIn];
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)build {
	self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.12];
	[self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(outside:)]];

	CGFloat w = kQuickCount * kItem + kItem + kPad * 2;
	_pill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, kPillH)];
	// shadow outside, gradient clipped inside
	_pill.layer.shadowColor = [UIColor blackColor].CGColor;
	_pill.layer.shadowOpacity = 0.35;
	_pill.layer.shadowRadius = 4;
	_pill.layer.shadowOffset = CGSizeMake(0, 2);
	_pill.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_pill.bounds cornerRadius:kPillH / 2].CGPath;
	CAGradientLayer *g = [CAGradientLayer layer];
	g.frame = _pill.bounds;
	g.colors = @[(id)WAColor(0xFFFFFF).CGColor, (id)WAColor(0xE6EAEF).CGColor];
	g.cornerRadius = kPillH / 2;
	g.masksToBounds = YES;
	g.borderWidth = 1;
	g.borderColor = WAColor(0xA9B1BC).CGColor;
	[_pill.layer addSublayer:g];
	// 1px shine at the top, ios 6 style
	CALayer *shine = [CALayer layer];
	shine.frame = CGRectMake(kPillH / 2, 1, w - kPillH, 1);
	shine.backgroundColor = [UIColor colorWithWhite:1 alpha:0.9].CGColor;
	[_pill.layer addSublayer:shine];

	for (int i = 0; i <= kQuickCount; i++) {
		UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
		b.frame = CGRectMake(kPad + i * kItem, (kPillH - kItem) / 2, kItem, kItem);
		b.tag = i;
		if (i < kQuickCount) {
			NSString *e = kQuick[i];
			if (_mine && [WAEmojiForDisplay(_mine) isEqualToString:WAEmojiForDisplay(e)]) {
				// own reaction: gray circle behind
				UIView *dot = [[UIView alloc] initWithFrame:CGRectInset(b.frame, 2, 2)];
				dot.backgroundColor = WAColor(0xD3D9E0);
				dot.layer.cornerRadius = (kItem - 4) / 2;
				dot.userInteractionEnabled = NO;
				[_pill addSubview:dot];
			}
			b.titleLabel.font = [UIFont systemFontOfSize:27];
			[b setTitle:QuickLabel(e) forState:UIControlStateNormal];
			[b addTarget:self action:@selector(picked:) forControlEvents:UIControlEventTouchUpInside];
		} else {
			[b setImage:PlusImage() forState:UIControlStateNormal];
			[b addTarget:self action:@selector(more) forControlEvents:UIControlEventTouchUpInside];
		}
		[_pill addSubview:b];
	}
	[self addSubview:_pill];
	[self placeAbove:self.bounds.size.height];
}

// above the bubble, below if no room, never under the keyboard
- (void)placeAbove:(CGFloat)bottom {
	CGSize size = self.bounds.size, p = _pill.bounds.size;
	BOOL mine = [_message[@"fromMe"] boolValue];
	CGFloat x = mine ? CGRectGetMaxX(_bubble) - p.width : _bubble.origin.x;
	x = MAX(8, MIN(size.width - 8 - p.width, x));
	CGFloat top = 44 + 6; // below the nav bar
	CGFloat y = _bubble.origin.y - p.height - 6;
	if (y < top) y = CGRectGetMaxY(_bubble) + 6;
	y = MAX(top, MIN(bottom - p.height - 8, y));
	_pill.center = CGPointMake(x + p.width / 2, y + p.height / 2);
}

- (void)popIn {
	_pill.alpha = 0;
	_pill.transform = CGAffineTransformMakeScale(0.4, 0.4);
	self.alpha = 0;
	[UIView animateWithDuration:0.16 animations:^{
		self.alpha = 1;
		self->_pill.alpha = 1;
		self->_pill.transform = CGAffineTransformMakeScale(1.06, 1.06);
	} completion:^(BOOL f) {
		[UIView animateWithDuration:0.08 animations:^{ self->_pill.transform = CGAffineTransformIdentity; }];
	}];
}

- (void)close {
	if (_done) return;
	_done = YES;
	if (_field) {
		// restore keyboard
		if (_previousMode && ![_previousMode hasPrefix:@"emoji"]) SetInputMode(_previousMode);
		[_field resignFirstResponder];
	}
	[UIView animateWithDuration:0.15 animations:^{
		self.alpha = 0;
		self->_pill.transform = CGAffineTransformMakeScale(0.8, 0.8);
	} completion:^(BOOL f) {
		[self removeFromSuperview];
	}];
}

- (void)outside:(UITapGestureRecognizer *)tap {
	if (!CGRectContainsPoint(_pill.frame, [tap locationInView:self])) [self close];
}

- (void)picked:(UIButton *)b {
	NSString *e = kQuick[b.tag];
	// same one again = remove, like whatsapp
	BOOL same = _mine && [WAEmojiForDisplay(_mine) isEqualToString:WAEmojiForDisplay(e)];
	[UIView animateWithDuration:0.1 animations:^{ b.transform = CGAffineTransformMakeScale(1.4, 1.4); }];
	[self send:same ? @"" : e];
}

- (void)send:(NSString *)emoji {
	if (_done) return;
	[[WAClient shared] post:@"/api/react" params:@{@"chat": _jid, @"id": _message[@"id"], @"emoji": emoji}
		completion:^(id json, NSError *error) {
			if (!error) return;
			[[[UIAlertView alloc] initWithTitle:@"Not sent" message:error.localizedDescription delegate:nil
				cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
		}];
	[self close];
}

#pragma mark Emoji keyboard

- (void)more {
	if (_field) return;
	// hidden field, first emoji typed gets sent
	_field = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
	_field.alpha = 0.02;
	_field.autocorrectionType = UITextAutocorrectionTypeNo;
	[_field addTarget:self action:@selector(typed) forControlEvents:UIControlEventEditingChanged];
	[self addSubview:_field];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:)
		name:UIKeyboardWillShowNotification object:nil];
	_previousMode = CurrentInputMode();
	[_field becomeFirstResponder];
	if (![_previousMode hasPrefix:@"emoji"]) SetInputMode(@"emoji@sw=Emoji");
}

- (void)keyboardWillShow:(NSNotification *)note {
	CGRect kb = [self convertRect:[note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil];
	[UIView animateWithDuration:0.25 animations:^{ [self placeAbove:kb.origin.y]; }];
}

- (void)typed {
	NSString *t = _field.text;
	if (!t.length) return;
	NSString *e = [t substringWithRange:[t rangeOfComposedCharacterSequenceAtIndex:t.length - 1]];
	_field.text = @"";
	if (![[e stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length]) return;
	[self send:e];
}

@end

#pragma mark - Reactions list

@interface WAReactionCell : UITableViewCell
@property (nonatomic, strong) UIImageView *avatar;
@property (nonatomic, strong) UILabel *emojiBadge, *name, *detail;
@end

@implementation WAReactionCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
	if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
		_avatar = [[UIImageView alloc] initWithFrame:CGRectMake(10, 9, 52, 52)];
		_avatar.contentMode = UIViewContentModeScaleAspectFill;
		_avatar.clipsToBounds = YES;
		_avatar.layer.cornerRadius = 4;
		_avatar.layer.borderWidth = 1;
		_avatar.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.2].CGColor;
		[self.contentView addSubview:_avatar];
		_emojiBadge = [[UILabel alloc] initWithFrame:CGRectMake(44, 41, 26, 24)];
		_emojiBadge.font = [UIFont systemFontOfSize:19];
		_emojiBadge.textAlignment = NSTextAlignmentCenter;
		_emojiBadge.backgroundColor = [UIColor clearColor];
		[self.contentView addSubview:_emojiBadge];
		_name = [[UILabel alloc] initWithFrame:CGRectMake(78, 13, 220, 24)];
		_name.font = [UIFont boldSystemFontOfSize:19];
		_name.backgroundColor = [UIColor clearColor];
		[self.contentView addSubview:_name];
		_detail = [[UILabel alloc] initWithFrame:CGRectMake(78, 38, 220, 20)];
		_detail.font = [UIFont systemFontOfSize:16];
		_detail.textColor = WAColor(0x7F7F7F);
		_detail.backgroundColor = [UIColor clearColor];
		[self.contentView addSubview:_detail];
	}
	return self;
}

@end

static NSString *ReactionTime(long long ts) {
	NSDate *d = [NSDate dateWithTimeIntervalSince1970:ts];
	NSCalendar *cal = [NSCalendar currentCalendar];
	NSDate *today = nil;
	[cal rangeOfUnit:NSDayCalendarUnit startDate:&today interval:NULL forDate:[NSDate date]];
	NSTimeInterval diff = [d timeIntervalSinceDate:today];
	NSString *day;
	if (diff >= 0) day = @"Today";
	else if (diff >= -86400) day = @"Yesterday";
	else {
		NSDateFormatter *f = [[NSDateFormatter alloc] init];
		f.dateFormat = @"dd/MM/yy";
		day = [f stringFromDate:d];
	}
	return [NSString stringWithFormat:@"%@ at %@", day, WAClockTime(ts)];
}

@implementation WAReactionsViewController {
	NSString *_jid;
	NSDictionary *_message;
	NSArray *_reactions;
}

- (instancetype)initWithChat:(NSString *)jid message:(NSDictionary *)message {
	if ((self = [super initWithStyle:UITableViewStylePlain])) {
		_jid = [jid copy];
		_message = message;
		_reactions = [[message[@"reactions"] reverseObjectEnumerator] allObjects]; // newest first
		self.title = @"Reactions";
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
		target:self action:@selector(done)];
	self.tableView.rowHeight = 70;
	self.tableView.tableHeaderView = [self messageHeader];
}

// message bubble on top
- (UIView *)messageHeader {
	CGFloat w = self.view.bounds.size.width;
	BOOL mine = [_message[@"fromMe"] boolValue];
	NSString *text = ShortText(_message);
	UIFont *font = [UIFont systemFontOfSize:16];
	CGSize ts = [text sizeWithFont:font constrainedToSize:CGSizeMake(220, 64) lineBreakMode:NSLineBreakByTruncatingTail];
	ts = CGSizeMake(ceilf(MAX(ts.width, 14)), ceilf(MAX(ts.height, 20)));
	CGSize bs = CGSizeMake(ts.width + 31, ts.height + 15);
	UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, bs.height + 36)];
	header.backgroundColor = WAColor(0xDBE2EC);
	CGRect bubble = CGRectMake(floorf((w - bs.width) / 2), 18, bs.width, bs.height);
	NSString *color = WABubbleColorName(_jid, mine);
	UIImage *img = WABubbleImage(color, mine);
	if (img) {
		UIImageView *iv = [[UIImageView alloc] initWithFrame:bubble];
		iv.image = img;
		[header addSubview:iv];
	} else {
		UIView *plain = [[UIView alloc] initWithFrame:CGRectInset(bubble, 2, 2)];
		plain.backgroundColor = WABubbleFill(color, mine);
		plain.layer.cornerRadius = 12;
		[header addSubview:plain];
	}
	UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(bubble.origin.x + (mine ? 10 : 21), bubble.origin.y + 6, ts.width, ts.height)];
	l.font = font;
	l.numberOfLines = 3;
	l.lineBreakMode = NSLineBreakByTruncatingTail;
	l.backgroundColor = [UIColor clearColor];
	l.text = text;
	[header addSubview:l];
	UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, header.bounds.size.height - 1, w, 1)];
	line.backgroundColor = WAColor(0xB4BCC6);
	[header addSubview:line];
	return header;
}

- (void)done {
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return _reactions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	WAReactionCell *cell = [tableView dequeueReusableCellWithIdentifier:@"r"];
	if (!cell) cell = [[WAReactionCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"r"];
	NSDictionary *r = _reactions[indexPath.row];
	BOOL mine = [r[@"fromMe"] boolValue];
	NSString *sender = r[@"sender"]; // own number = me
	cell.name.text = mine ? @"You" : ([r[@"name"] length] ? r[@"name"] : r[@"sender"]);
	cell.detail.text = mine ? @"Tap to remove" : ReactionTime([r[@"ts"] longLongValue]);
	cell.emojiBadge.text = WAEmojiForDisplay(r[@"emoji"]);
	cell.selectionStyle = mine ? UITableViewCellSelectionStyleBlue : UITableViewCellSelectionStyleNone;
	cell.avatar.image = (sender ? [[WAClient shared] cachedAvatarFor:sender] : nil) ?: WAImg(@"EmptyContact");
	cell.tag = indexPath.row;
	if (sender) {
		[[WAClient shared] avatarFor:sender completion:^(UIImage *image) {
			if (image && cell.tag == indexPath.row) cell.avatar.image = image; // cell got reused
		}];
	}
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (![_reactions[indexPath.row][@"fromMe"] boolValue]) return;
	UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:nil delegate:(id<UIActionSheetDelegate>)self
		cancelButtonTitle:@"Cancel" destructiveButtonTitle:@"Remove Reaction" otherButtonTitles:nil];
	[sheet showInView:self.view];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
	if (index != sheet.destructiveButtonIndex) return;
	[[WAClient shared] post:@"/api/react" params:@{@"chat": _jid, @"id": _message[@"id"], @"emoji": @""}
		completion:^(id json, NSError *error) {
			if (error) {
				[[[UIAlertView alloc] initWithTitle:nil message:error.localizedDescription delegate:nil
					cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
				return;
			}
			[self done];
		}];
}

@end
