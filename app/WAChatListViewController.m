#import <QuartzCore/QuartzCore.h>
#import "WAChatListViewController.h"
#import "WAChatViewController.h"
#import "WAClient.h"
#import "WAAssets.h"
#import "WAUtil.h"
#import "WANewGroupViewController.h"
#import "WAPersonPicker.h"
#import "WABroadcasts.h"

// 2.10 row: avatar, name, time, last msg, badge, arrow
@interface WAChatCell : UITableViewCell
@property (nonatomic, strong) UIImageView *avatar, *statusIcon;
@property (nonatomic, strong) UILabel *nameLabel, *timeLabel, *senderLabel, *lastLabel, *badgeLabel;
@property (nonatomic, strong) UIImageView *muteIcon;
@property (nonatomic, copy) NSString *jid;
@end

@implementation WAChatCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
	if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
		self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		_avatar = [[UIImageView alloc] init];
		_avatar.contentMode = UIViewContentModeScaleAspectFill;
		_avatar.clipsToBounds = YES;
		_avatar.layer.cornerRadius = 4;
		[self.contentView addSubview:_avatar];
		_nameLabel = [self label:[UIFont boldSystemFontOfSize:17] color:[UIColor blackColor]];
		_timeLabel = [self label:[UIFont systemFontOfSize:14] color:WAColor(0x2470D8)];
		_timeLabel.textAlignment = NSTextAlignmentRight;
		_senderLabel = [self label:[UIFont systemFontOfSize:15] color:[UIColor blackColor]];
		_lastLabel = [self label:[UIFont systemFontOfSize:15] color:WAColor(0x7F7F7F)];
		_lastLabel.numberOfLines = 2;
		_muteIcon = [[UIImageView alloc] initWithImage:WAImg(@"MuteIndicator")];
		_muteIcon.contentMode = UIViewContentModeCenter;
		[self.contentView addSubview:_muteIcon];
		_statusIcon = [[UIImageView alloc] init];
		_statusIcon.contentMode = UIViewContentModeCenter;
		[self.contentView addSubview:_statusIcon];
		_badgeLabel = [self label:[UIFont boldSystemFontOfSize:14] color:[UIColor whiteColor]];
		_badgeLabel.textAlignment = NSTextAlignmentCenter;
		_badgeLabel.backgroundColor = WAColor(0x8C929C);
		_badgeLabel.layer.cornerRadius = 5;
		_badgeLabel.layer.masksToBounds = YES;
		_badgeLabel.highlightedTextColor = [UIColor whiteColor];
	}
	return self;
}

- (UILabel *)label:(UIFont *)font color:(UIColor *)color {
	UILabel *l = [[UILabel alloc] init];
	l.font = font;
	l.textColor = color;
	l.backgroundColor = [UIColor clearColor];
	l.highlightedTextColor = [UIColor whiteColor];
	[self.contentView addSubview:l];
	return l;
}

- (void)layoutSubviews {
	[super layoutSubviews];
	CGFloat w = self.contentView.bounds.size.width;
	self.avatar.frame = CGRectMake(6, 6, 52, 52);
	CGFloat x = 66;
	CGSize time = [self.timeLabel.text sizeWithFont:self.timeLabel.font];
	self.timeLabel.frame = CGRectMake(w - time.width - 4, 8, time.width, 18);
	// muted icon
	CGFloat mute = self.muteIcon.hidden ? 0 : 20;
	self.muteIcon.frame = CGRectMake(w - time.width - 4 - mute, 8, 18, 18);
	self.nameLabel.frame = CGRectMake(x, 6, w - x - time.width - 10 - mute, 21);
	CGFloat right = w - 4;
	if (!self.badgeLabel.hidden) {
		CGFloat bw = MAX(22, [self.badgeLabel.text sizeWithFont:self.badgeLabel.font].width + 10);
		self.badgeLabel.frame = CGRectMake(w - bw - 2, 34, bw, 20);
		right = w - bw - 8;
	}
	CGFloat y = 27;
	if (!self.senderLabel.hidden) {
		self.senderLabel.frame = CGRectMake(x, y, right - x, 18);
		y += 18;
	}
	CGFloat textX = x;
	if (!self.statusIcon.hidden) {
		self.statusIcon.frame = CGRectMake(x, y + 1, 17, 16);
		textX = x + 19;
	}
	self.lastLabel.numberOfLines = self.senderLabel.hidden ? 2 : 1;
	CGSize last = [self.lastLabel.text sizeWithFont:self.lastLabel.font constrainedToSize:CGSizeMake(right - textX, 36)
		lineBreakMode:NSLineBreakByTruncatingTail];
	self.lastLabel.frame = CGRectMake(textX, y, right - textX, MAX(18, MIN(last.height, self.senderLabel.hidden ? 36 : 18)));
}

@end

// empty list and no answer: ios 6 style note (grey, white shadow, like "No Recents")
@interface WANoNetworkView : UIView
@property (nonatomic, strong) UILabel *titleLabel, *textLabel;
@property (nonatomic, strong) UIImageView *glyph;
@property (nonatomic, strong) UIButton *retry;
@end

@implementation WANoNetworkView

// embossed wifi waves
+ (UIImage *)wavesGlyph {
	CGSize s = CGSizeMake(70, 52);
	UIGraphicsBeginImageContextWithOptions(s, NO, 0);
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	CGContextSetShadowWithColor(ctx, CGSizeMake(0, 1), 0, [UIColor whiteColor].CGColor);
	[WAColor(0xAEB4BC) set];
	CGPoint c = CGPointMake(35, 46);
	for (int i = 1; i <= 3; i++) {
		UIBezierPath *arc = [UIBezierPath bezierPathWithArcCenter:c radius:12 * i + 2 startAngle:M_PI * 1.25 endAngle:M_PI * 1.75 clockwise:YES];
		arc.lineWidth = 6;
		arc.lineCapStyle = kCGLineCapRound;
		[arc stroke];
	}
	[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - 4.5, c.y - 4.5, 9, 9)] fill];
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

- (UILabel *)labelWithFont:(UIFont *)font {
	UILabel *l = [[UILabel alloc] init];
	l.font = font;
	l.textColor = WAColor(0x7F8790);
	l.shadowColor = [UIColor whiteColor];
	l.shadowOffset = CGSizeMake(0, 1);
	l.backgroundColor = [UIColor clearColor];
	l.textAlignment = NSTextAlignmentCenter;
	l.numberOfLines = 0;
	[self addSubview:l];
	return l;
}

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.backgroundColor = [UIColor whiteColor];
		_glyph = [[UIImageView alloc] initWithImage:[WANoNetworkView wavesGlyph]];
		[self addSubview:_glyph];
		_titleLabel = [self labelWithFont:[UIFont boldSystemFontOfSize:20]];
		_textLabel = [self labelWithFont:[UIFont systemFontOfSize:15]];
		_retry = [UIButton buttonWithType:UIButtonTypeRoundedRect];
		_retry.titleLabel.font = [UIFont boldSystemFontOfSize:15];
		[_retry setTitle:WAL(@"Try Again") forState:UIControlStateNormal];
		[_retry setTitleColor:WAColor(0x37588C) forState:UIControlStateNormal];
		[self addSubview:_retry];
	}
	return self;
}

- (void)layoutSubviews {
	[super layoutSubviews];
	CGFloat w = self.bounds.size.width, textW = w - 60;
	CGSize title = [_titleLabel.text sizeWithFont:_titleLabel.font constrainedToSize:CGSizeMake(textW, 200)];
	CGSize text = [_textLabel.text sizeWithFont:_textLabel.font constrainedToSize:CGSizeMake(textW, 200)];
	CGSize g = _glyph.image.size;
	CGFloat h = g.height + 18 + title.height + 8 + text.height + 22 + 34;
	CGFloat y = MAX(20, roundf((self.bounds.size.height - h) / 2 - 10));
	_glyph.frame = CGRectMake(roundf((w - g.width) / 2), y, g.width, g.height);
	y += g.height + 18;
	_titleLabel.frame = CGRectMake(30, y, textW, title.height);
	y += title.height + 8;
	_textLabel.frame = CGRectMake(30, y, textW, text.height);
	y += text.height + 22;
	_retry.frame = CGRectMake(roundf((w - 130) / 2), y, 130, 34);
}

@end

@interface WAChatListViewController ()
- (NSDictionary *)chatAtIndexPath:(NSIndexPath *)indexPath;
- (instancetype)initArchivedOnly;
- (void)updateTableHeader;
- (UIView *)archivedRowWithWidth:(CGFloat)width;
- (void)openArchivedChats;
- (NSInteger)archivedCount;
@end

@interface WAArchivedGlyphView : UIView
@end

@implementation WAArchivedGlyphView
- (void)drawRect:(CGRect)rect {
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	CGContextSetStrokeColorWithColor(ctx, WAColor(0x7F7F7F).CGColor);
	CGContextSetLineWidth(ctx, 1.3);
	CGContextSetLineCap(ctx, kCGLineCapRound);
	CGContextMoveToPoint(ctx, 3, 8);
	CGContextAddLineToPoint(ctx, 3, 17);
	CGContextAddLineToPoint(ctx, 17, 17);
	CGContextAddLineToPoint(ctx, 17, 8);
	CGContextMoveToPoint(ctx, 2, 7);
	CGContextAddLineToPoint(ctx, 18, 7);
	CGContextMoveToPoint(ctx, 10, 1);
	CGContextAddLineToPoint(ctx, 10, 12);
	CGContextMoveToPoint(ctx, 7, 9);
	CGContextAddLineToPoint(ctx, 10, 12);
	CGContextAddLineToPoint(ctx, 13, 9);
	CGContextStrokePath(ctx);
}
@end

@implementation WAChatListViewController {
	NSArray *_chats;
	NSError *_loadError;
	WANoNetworkView *_noNetwork;
	BOOL _loading;
	BOOL _archivedOnly;
	BOOL _showArchivedShortcut;
	UIBarButtonItem *_penItem, *_deleteAllItem;
	NSDictionary *_deleting; // nil = all
}

- (instancetype)initArchivedOnly {
	if ((self = [self initWithStyle:UITableViewStylePlain])) _archivedOnly = YES;
	return self;
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
	if ((self = [super initWithStyle:style])) {
		self.title = WAL(@"Chats");
		self.tabBarItem = [[UITabBarItem alloc] initWithTitle:WAL(@"Chats") image:WAImg(@"Chats") tag:3];
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.tableView.rowHeight = 64;
	if ([self.tableView respondsToSelector:@selector(setAlwaysBounceVertical:)]) self.tableView.alwaysBounceVertical = YES;
	if (_archivedOnly) {
		self.title = WAL(@"Archived");
	} else {
		self.navigationItem.leftBarButtonItem = self.editButtonItem;
		self.editButtonItem.title = WAL(@"Edit");
	}
	UIImage *pen = [self whiteGlyph:WAImg(@"Pen")];
	_penItem = pen
		? [[UIBarButtonItem alloc] initWithImage:pen style:UIBarButtonItemStyleBordered target:self action:@selector(compose)]
		: [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCompose target:self action:@selector(compose)];
	_deleteAllItem = [[UIBarButtonItem alloc] initWithTitle:WAL(@"Delete All") style:UIBarButtonItemStyleBordered
		target:self action:@selector(deleteAllTapped)];
	if (!_archivedOnly) {
		self.navigationItem.rightBarButtonItem = _penItem;
		[self updateTableHeader];
	}
	if (NSClassFromString(@"UIRefreshControl")) { // ios 6 only
		UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
		[refresh addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
		self.refreshControl = refresh;
	}
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updatesArrived:)
		name:WAClientUpdatesNotification object:nil];
	// back online / other address: try again by itself
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(networkChanged)
		name:WAClientNetworkChangedNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(networkChanged)
		name:WAClientServerChangedNotification object:nil];
}

- (void)networkChanged {
	if (!_loadError || ![WAClient shared].networkUp) {
		[self updateEmptyState];
		return;
	}
	// chooseServer is still asking, give it a moment
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reload) object:nil];
	[self performSelector:@selector(reload) withObject:nil afterDelay:1.5];
}

// note over the empty list when the bridge didn't answer. as footer so the button gets touches and no empty separators show
- (void)updateEmptyState {
	BOOL show = _loadError && !_chats.count;
	if (!show) {
		if (_noNetwork) {
			self.tableView.tableFooterView = nil;
			_noNetwork = nil;
		}
		return;
	}
	BOOL offline = ![WAClient shared].networkUp || _loadError.code == NSURLErrorNotConnectedToInternet;
	CGFloat h = self.tableView.bounds.size.height - self.tableView.tableHeaderView.bounds.size.height;
	if (!_noNetwork) {
		_noNetwork = [[WANoNetworkView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, MAX(h, 280))];
		[_noNetwork.retry addTarget:self action:@selector(reload) forControlEvents:UIControlEventTouchUpInside];
	}
	_noNetwork.titleLabel.text = offline ? WAL(@"No Network Connection") : WAL(@"Cannot Reach Your Bridge");
	_noNetwork.textLabel.text = offline
		? WAL(@"Your chats will show up as soon as your iPhone is connected to the Internet.")
		: WAL(@"Make sure your bridge computer is turned on and connected.");
	[_noNetwork setNeedsLayout];
	if (self.tableView.tableFooterView != _noNetwork) self.tableView.tableFooterView = _noNetwork;
}

// broadcast / new group bar
- (UIView *)headerBar {
	UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
	bar.backgroundColor = WAColor(0xD7DEE6);
	UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 43, 320, 1)];
	line.backgroundColor = WAColor(0xB4BCC6);
	line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[bar addSubview:line];
	NSArray *titles = @[WAL(@"Broadcast Message"), WAL(@"New Group")];
	CGRect frames[] = {CGRectMake(7, 7, 177, 30), CGRectMake(192, 7, 121, 30)};
	for (NSUInteger i = 0; i < titles.count; i++) {
		UIButton *b = [UIButton buttonWithType:UIButtonTypeRoundedRect];
		b.frame = frames[i];
		// smaller font when the translation is long ("Nouveau groupe")
		CGFloat size = 15;
		while (size > 11 && [titles[i] sizeWithFont:[UIFont boldSystemFontOfSize:size]].width > b.frame.size.width - 14) size -= 0.5f;
		b.titleLabel.font = [UIFont boldSystemFontOfSize:size];
		[b setTitle:titles[i] forState:UIControlStateNormal];
		[b setTitleColor:WAColor(0x37588C) forState:UIControlStateNormal];
		[b addTarget:self action:i == 1 ? @selector(newGroup) : @selector(broadcast) forControlEvents:UIControlEventTouchUpInside];
		[bar addSubview:b];
	}
	return bar;
}

- (void)newGroup {
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[WANewGroupViewController alloc] init]];
	[self presentViewController:nav animated:YES completion:nil];
}

// white pen with shadow
- (UIImage *)whiteGlyph:(UIImage *)img {
	if (!img) return nil;
	CGSize s = img.size;
	UIGraphicsBeginImageContextWithOptions(CGSizeMake(s.width, s.height + 1), NO, img.scale);
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	CGContextSetShadowWithColor(ctx, CGSizeMake(0, -1), 0, [UIColor colorWithWhite:0 alpha:0.5].CGColor);
	CGContextBeginTransparencyLayer(ctx, NULL);
	[img drawInRect:CGRectMake(0, 0, s.width, s.height)];
	CGContextSetBlendMode(ctx, kCGBlendModeSourceIn);
	[[UIColor whiteColor] setFill];
	CGContextFillRect(ctx, CGRectMake(0, 0, s.width, s.height + 1));
	CGContextEndTransparencyLayer(ctx);
	UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return out;
}

// new message picker
- (void)compose {
	WAPersonPicker *picker = [[WAPersonPicker alloc] init];
	picker.onPick = ^(NSDictionary *c) {
		[[NSNotificationCenter defaultCenter] postNotificationName:@"WAOpenChatNotification" object:nil
			userInfo:@{@"jid": c[@"jid"], @"name": c[@"name"] ?: @""}];
	};
	[self presentViewController:[[UINavigationController alloc] initWithRootViewController:picker] animated:YES completion:nil];
}

- (void)broadcast {
	[WABroadcastListViewController openFrom:self];
}

#pragma mark - Edit: delete chats (WhatsApp 2.10's edit mode)

// edit mode
- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
	if (_archivedOnly) return;
	[super setEditing:editing animated:animated];
	self.editButtonItem.title = editing ? WAL(@"Done") : WAL(@"Edit");
	[self.navigationItem setRightBarButtonItem:editing ? _deleteAllItem : _penItem animated:animated];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
	return UITableViewCellEditingStyleDelete;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
	if (style != UITableViewCellEditingStyleDelete) return;
	_deleting = [self chatAtIndexPath:indexPath];
	if (!_deleting) return;
	[self askHowToDelete:[NSString stringWithFormat:WAL(@"Delete All Chat History with “%@”"), _deleting[@"name"]]];
}

- (void)deleteAllTapped {
	if (!_chats.count) return;
	_deleting = nil;
	[self askHowToDelete:WAL(@"Delete All Chat History with All Contacts")];
}

// delete here only or everywhere
- (void)askHowToDelete:(NSString *)title {
	UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:title delegate:self cancelButtonTitle:WAL(@"Cancel")
		destructiveButtonTitle:WAL(@"Delete Everywhere") otherButtonTitles:WAL(@"Delete on This iPhone"), nil];
	sheet.tag = 7;
	[sheet showInView:self.tabBarController.view ?: self.view];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
	if (sheet.tag != 7) return;
	if (index == sheet.cancelButtonIndex) {
		[self.tableView setEditing:self.editing animated:YES];
		return;
	}
	BOOL everywhere = index == sheet.destructiveButtonIndex;
	NSDictionary *chat = _deleting;
	NSDictionary *params = chat ? @{@"chat": chat[@"jid"], @"everywhere": everywhere ? @"1" : @"0"}
		: @{@"all": @"1", @"everywhere": everywhere ? @"1" : @"0"};
	// remove right away
	NSMutableArray *left = [_chats mutableCopy];
	if (chat) {
		NSUInteger row = [_chats indexOfObject:chat];
		[left removeObject:chat];
		_chats = left;
		if (row != NSNotFound) {
			[self.tableView reloadData];
		}
	} else {
		_chats = @[];
		[self.tableView reloadData];
		[self setEditing:NO animated:YES];
	}
	[[WAClient shared] post:@"/api/chat/delete" params:params completion:^(id json, NSError *error) {
		if (error) {
			[[[UIAlertView alloc] initWithTitle:WAL(@"Not deleted") message:error.localizedDescription delegate:nil
				cancelButtonTitle:WAL(@"OK") otherButtonTitles:nil] show];
		}
		[self reload];
	}];
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self reload];
}

// no refreshControl on ios 4
- (void)endRefreshing {
	if ([self respondsToSelector:@selector(refreshControl)]) [self.refreshControl endRefreshing];
}

- (void)reload {
	WAClient *client = [WAClient shared];
	if (!client.configured || _loading) {
		[self endRefreshing];
		return;
	}
	_loading = YES;
	[client get:@"/api/chats" params:nil completion:^(id json, NSError *error) {
		self->_loading = NO;
		[self endRefreshing];
		self->_loadError = error;
		if (error) {
			self.navigationItem.title = WAL(@"Waiting for network"); // not self.title, that renames the tab too
			[self updateEmptyState];
			return;
		}
		self.navigationItem.title = self->_archivedOnly ? WAL(@"Archived") : WAL(@"Chats");
		self->_chats = json[@"chats"];
		if (![self archivedCount]) self->_showArchivedShortcut = NO;
		if (!self->_archivedOnly) [self updateTableHeader];
		[self updateEmptyState];
		[self.tableView reloadData];
		[self updateBadge];
		[client startUpdatesFrom:[json[@"upd"] longLongValue]];
	}];
}

- (void)updateBadge {
	NSInteger unread = 0, chats = 0;
	for (NSDictionary *c in _chats) {
		if ([c[@"archived"] boolValue]) continue; // like WhatsApp, archived chats don't count
		NSInteger n = [c[@"unread"] integerValue];
		unread += n;
		if (n) chats++;
	}
	[UIApplication sharedApplication].applicationIconBadgeNumber = unread;
	self.navigationController.tabBarItem.badgeValue = chats ? [@(chats) description] : nil;
	// "Chats (1)" back button
	NSString *back = chats ? [NSString stringWithFormat:WAL(@"Chats (%ld)"), (long)chats] : WAL(@"Chats");
	self.navigationItem.backBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:back style:UIBarButtonItemStyleBordered
		target:nil action:nil];
}

- (void)updatesArrived:(NSNotification *)note {
	if (![note.userInfo[@"messages"] count] && ![note.userInfo[@"chatsChanged"] boolValue]) return;
	// batch reloads (history sync)
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reload) object:nil];
	[self performSelector:@selector(reload) withObject:nil afterDelay:0.4];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	NSInteger count = 0;
	for (NSDictionary *chat in _chats) if ([chat[@"archived"] boolValue] == _archivedOnly) count++;
	return count;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return 1;
}

- (NSInteger)archivedCount {
	NSInteger count = 0;
	for (NSDictionary *chat in _chats) if ([chat[@"archived"] boolValue]) count++;
	return count;
}

// table header = broadcast/group bar, plus the archived row once pulled. scrolls with the chats, a section header would stick
- (void)updateTableHeader {
	CGFloat w = self.tableView.bounds.size.width ?: 320;
	BOOL archived = _showArchivedShortcut && [self archivedCount];
	UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, archived ? 88 : 44)];
	UIView *bar = [self headerBar];
	bar.frame = CGRectMake(0, 0, w, 44);
	bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[header addSubview:bar];
	if (archived) {
		UIView *row = [self archivedRowWithWidth:w];
		row.frame = CGRectMake(0, 44, w, 44);
		[header addSubview:row];
	}
	self.tableView.tableHeaderView = header;
}

- (UIView *)archivedRowWithWidth:(CGFloat)width {
	UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 44)];
	row.backgroundColor = [UIColor whiteColor];
	row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
	button.frame = row.bounds;
	button.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
	[button addTarget:self action:@selector(openArchivedChats) forControlEvents:UIControlEventTouchUpInside];
	WAArchivedGlyphView *glyph = [[WAArchivedGlyphView alloc] initWithFrame:CGRectMake(18, 13, 20, 18)];
	glyph.backgroundColor = [UIColor clearColor];
	[button addSubview:glyph];
	UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(58, 0, 190, 44)];
	title.text = WAL(@"Archived");
	title.font = [UIFont systemFontOfSize:16];
	title.textColor = WAColor(0x37588C);
	title.backgroundColor = [UIColor clearColor];
	[button addSubview:title];
	UILabel *count = [[UILabel alloc] initWithFrame:CGRectMake(width - 48, 0, 30, 44)];
	count.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
	count.text = [NSString stringWithFormat:@"%ld", (long)[self archivedCount]];
	count.textAlignment = NSTextAlignmentRight;
	count.font = [UIFont systemFontOfSize:14];
	count.textColor = WAColor(0x7F7F7F);
	count.backgroundColor = [UIColor clearColor];
	[button addSubview:count];
	UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 43, width, 1)];
	line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	line.backgroundColor = WAColor(0xE5E5E5);
	[button addSubview:line];
	[row addSubview:button];
	return row;
}

- (NSDictionary *)chatAtIndexPath:(NSIndexPath *)indexPath {
	NSInteger row = 0;
	for (NSDictionary *chat in _chats) {
		if ([chat[@"archived"] boolValue] != _archivedOnly) continue;
		if (row++ == indexPath.row) return chat;
	}
	return nil;
}

- (void)openArchivedChats {
	WAChatListViewController *archived = [[WAChatListViewController alloc] initArchivedOnly];
	[self.navigationController pushViewController:archived animated:YES];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
	if (_archivedOnly || _showArchivedShortcut || ![self archivedCount]) return;
	// Reveal the shortcut with a light pull, before the refresh control's trigger distance.
	if (scrollView.contentOffset.y < -44) {
		_showArchivedShortcut = YES;
		[self.tableView beginUpdates];
		[self updateTableHeader];
		[self.tableView endUpdates];
	}
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	WAChatCell *cell = [tableView dequeueReusableCellWithIdentifier:@"chat"];
	if (!cell) cell = [[WAChatCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"chat"];
	NSDictionary *chat = [self chatAtIndexPath:indexPath];
	if (!chat) return cell;
	BOOL group = [chat[@"group"] boolValue];
	NSString *jid = chat[@"jid"];
	cell.jid = jid;
	cell.nameLabel.text = chat[@"name"];
	cell.muteIcon.hidden = ![chat[@"muted"] boolValue] || !cell.muteIcon.image;
	cell.timeLabel.text = WAShortTime([chat[@"lastTS"] longLongValue]);

	NSString *kind = chat[@"lastKind"];
	BOOL fromMe = [chat[@"lastFromMe"] boolValue];
	NSString *text = chat[@"lastText"];
	if ([kind isEqualToString:@"call"]) {
		text = WACallText(@{@"text": text ?: @"", @"fromMe": @(fromMe), @"secs": chat[@"lastSecs"] ?: @0});
	} else if ([kind isEqualToString:@"audio"]) {
		NSInteger secs = [chat[@"lastSecs"] integerValue];
		text = secs ? [NSString stringWithFormat:@"%ld:%02ld", (long)(secs / 60), (long)(secs % 60)] : WAL(@"Audio");
	}
	NSString *sender = chat[@"lastSenderName"];
	cell.senderLabel.hidden = !(group && !fromMe && sender.length);
	cell.senderLabel.text = [sender stringByAppendingString:@":"];
	if (group && fromMe && ![kind isEqualToString:@"system"]) text = [WAL(@"You: ") stringByAppendingString:text ?: @""];
	cell.lastLabel.text = text;

	// tick/mic icon
	UIImage *icon = nil;
	if ([kind isEqualToString:@"audio"]) icon = WAImg(fromMe ? @"MicChatsBlue" : @"MicChats");
	else if (fromMe && ![kind isEqualToString:@"call"]) {
		int status = [chat[@"lastStatus"] intValue];
		icon = status >= 3 && !group ? WAReadTick() : WAImg(status >= 2 ? @"mark_d" : @"mark_s");
	}
	cell.statusIcon.image = icon;
	cell.statusIcon.hidden = icon == nil;

	NSInteger unread = [chat[@"unread"] integerValue];
	cell.badgeLabel.hidden = unread == 0;
	cell.badgeLabel.text = [@(unread) description];

	UIImage *placeholder = WAImg(group ? @"GroupChat" : @"EmptyContact");
	cell.avatar.image = [[WAClient shared] cachedAvatarFor:jid] ?: placeholder;
	[[WAClient shared] avatarFor:jid completion:^(UIImage *image) {
		if (image && [cell.jid isEqualToString:jid]) cell.avatar.image = image;
	}];
	[cell setNeedsLayout];
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	NSDictionary *chat = [self chatAtIndexPath:indexPath];
	if (!chat) return;
	WAChatViewController *vc = [[WAChatViewController alloc] initWithChat:chat];
	[self.navigationController pushViewController:vc animated:YES];
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
}

@end
