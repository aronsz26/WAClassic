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

@interface WAChatListViewController ()
- (NSDictionary *)chatAtIndexPath:(NSIndexPath *)indexPath;
@end

@implementation WAChatListViewController {
	NSArray *_chats;
	BOOL _loading;
	UIBarButtonItem *_penItem, *_deleteAllItem;
	NSDictionary *_deleting; // nil = all
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
	if ((self = [super initWithStyle:style])) {
		self.title = @"Chats";
		self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Chats" image:WAImg(@"Chats") tag:3];
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.tableView.rowHeight = 64;
	self.navigationItem.leftBarButtonItem = self.editButtonItem;
	self.editButtonItem.title = @"Edit";
	UIImage *pen = [self whiteGlyph:WAImg(@"Pen")];
	_penItem = pen
		? [[UIBarButtonItem alloc] initWithImage:pen style:UIBarButtonItemStyleBordered target:self action:@selector(compose)]
		: [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCompose target:self action:@selector(compose)];
	_deleteAllItem = [[UIBarButtonItem alloc] initWithTitle:@"Delete All" style:UIBarButtonItemStyleBordered
		target:self action:@selector(deleteAllTapped)];
	self.navigationItem.rightBarButtonItem = _penItem;
	self.tableView.tableHeaderView = [self headerBar];
	if (NSClassFromString(@"UIRefreshControl")) { // ios 6 only
		UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
		[refresh addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
		self.refreshControl = refresh;
	}
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updatesArrived:)
		name:WAClientUpdatesNotification object:nil];
}

// broadcast / new group bar
- (UIView *)headerBar {
	UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
	bar.backgroundColor = WAColor(0xD7DEE6);
	UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 43, 320, 1)];
	line.backgroundColor = WAColor(0xB4BCC6);
	line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[bar addSubview:line];
	NSArray *titles = @[@"Broadcast Message", @"New Group"];
	CGRect frames[] = {CGRectMake(7, 7, 177, 30), CGRectMake(192, 7, 121, 30)};
	for (NSUInteger i = 0; i < titles.count; i++) {
		UIButton *b = [UIButton buttonWithType:UIButtonTypeRoundedRect];
		b.frame = frames[i];
		b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
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
	[super setEditing:editing animated:animated];
	self.editButtonItem.title = editing ? @"Done" : @"Edit";
	[self.navigationItem setRightBarButtonItem:editing ? _deleteAllItem : _penItem animated:animated];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
	return UITableViewCellEditingStyleDelete;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
	if (style != UITableViewCellEditingStyleDelete) return;
	_deleting = [self chatAtIndexPath:indexPath];
	if (!_deleting) return;
	[self askHowToDelete:[NSString stringWithFormat:@"Delete All Chat History with “%@”", _deleting[@"name"]]];
}

- (void)deleteAllTapped {
	if (!_chats.count) return;
	_deleting = nil;
	[self askHowToDelete:@"Delete All Chat History with All Contacts"];
}

// delete here only or everywhere
- (void)askHowToDelete:(NSString *)title {
	UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:title delegate:self cancelButtonTitle:@"Cancel"
		destructiveButtonTitle:@"Delete Everywhere" otherButtonTitles:@"Delete on This iPhone", nil];
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
			[[[UIAlertView alloc] initWithTitle:@"Not deleted" message:error.localizedDescription delegate:nil
				cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
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
		if (error) {
			self.title = @"Waiting for network";
			return;
		}
		self.title = @"Chats";
		self->_chats = json[@"chats"];
		[self.tableView reloadData];
		[self updateBadge];
		[client startUpdatesFrom:[json[@"upd"] longLongValue]];
	}];
}

- (void)updateBadge {
	NSInteger unread = 0, chats = 0;
	for (NSDictionary *c in _chats) {
		NSInteger n = [c[@"unread"] integerValue];
		unread += n;
		if (n) chats++;
	}
	[UIApplication sharedApplication].applicationIconBadgeNumber = unread;
	self.navigationController.tabBarItem.badgeValue = chats ? [@(chats) description] : nil;
	// "Chats (1)" back button
	NSString *back = chats ? [NSString stringWithFormat:@"Chats (%ld)", (long)chats] : @"Chats";
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
	for (NSDictionary *chat in _chats) if ([chat[@"archived"] boolValue] == (section == 1)) count++;
	return count;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	BOOL hasArchived = NO;
	for (NSDictionary *chat in _chats) if ([chat[@"archived"] boolValue]) { hasArchived = YES; break; }
	return hasArchived ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	return section == 1 ? @"Archived" : nil;
}

- (NSDictionary *)chatAtIndexPath:(NSIndexPath *)indexPath {
	BOOL archived = indexPath.section == 1;
	NSInteger row = 0;
	for (NSDictionary *chat in _chats) {
		if ([chat[@"archived"] boolValue] != archived) continue;
		if (row++ == indexPath.row) return chat;
	}
	return nil;
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
		text = secs ? [NSString stringWithFormat:@"%ld:%02ld", (long)(secs / 60), (long)(secs % 60)] : @"Audio";
	}
	NSString *sender = chat[@"lastSenderName"];
	cell.senderLabel.hidden = !(group && !fromMe && sender.length);
	cell.senderLabel.text = [sender stringByAppendingString:@":"];
	if (group && fromMe && ![kind isEqualToString:@"system"]) text = [@"You: " stringByAppendingString:text ?: @""];
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
