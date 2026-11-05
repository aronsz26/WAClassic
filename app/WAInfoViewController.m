#import <QuartzCore/QuartzCore.h>
#import "WAInfoViewController.h"
#import "WAMediaViewController.h"
#import "WAClient.h"
#import "WACall.h"
#import "WAAssets.h"
#import "WAUtil.h"
#import "WAPrefs.h"
#import "WASettingsPages.h"
#import "WAFavoritesViewController.h"
#import "WASubjectEditController.h"
#import "WAPersonPicker.h"

@interface WAInfoViewController () <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@end

typedef NS_ENUM(NSInteger, WARow) { WARowPhone, WARowTopic, WARowMedia, WARowMute, WARowMember, WARowMessage, WARowCall, WARowBlock, WARowBubbles, WARowFavorite };

@implementation WAInfoViewController {
	NSString *_jid, *_name;
	BOOL _group;
	NSDictionary *_info;
	NSArray *_sections; // rows per section
	UIImageView *_picture;
	UILabel *_nameLabel, *_aboutLabel, *_subLabel;
	NSNumber *_blocked;
	UITableView *_subjectTable; // subject table next to the pic
	NSDictionary *_selected;
}

- (instancetype)initWithJID:(NSString *)jid name:(NSString *)name group:(BOOL)group {
	if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
		_jid = [jid copy];
		_name = [name copy];
		_group = group;
		self.title = group ? @"Group Info" : @"Contact Info";
	}
	return self;
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self.tableView reloadData];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.tableView.tableHeaderView = [self headerView];
	[self rebuildSections];
	[self load];
	if (!_group) [self loadBlocked];
}

- (void)loadBlocked {
	[[WAClient shared] get:@"/api/blocklist" params:nil completion:^(id json, NSError *error) {
		if (![json[@"blocked"] isKindOfClass:[NSArray class]]) return;
		BOOL found = NO;
		for (NSDictionary *c in json[@"blocked"]) if ([c[@"jid"] isEqualToString:self->_jid]) found = YES;
		self->_blocked = @(found);
		[self rebuildSections];
		[self.tableView reloadData];
	}];
}

- (void)load {
	NSString *path = _group ? @"/api/chatinfo" : @"/api/contactinfo";
	NSDictionary *params = _group ? @{@"chat": _jid} : @{@"jid": _jid};
	[[WAClient shared] get:path params:params completion:^(id json, NSError *error) {
		if (![json isKindOfClass:[NSDictionary class]]) return;
		self->_info = json;
		[self fillHeader];
		[self rebuildSections];
		[self.tableView reloadData];
	}];
}

- (void)rebuildSections {
	NSMutableArray *s = [NSMutableArray array];
	if (_group) {
		if ([_info[@"topic"] length]) [s addObject:@[@(WARowTopic)]];
		[s addObject:@[@(WARowMedia), @(WARowMute), @(WARowBubbles)]];
		if ([_info[@"participants"] count]) [s addObject:@[@(WARowMember)]];
	} else {
		[s addObject:@[@(WARowMessage), @(WARowCall), @(WARowFavorite)]];
		if ([_info[@"phone"] length]) [s addObject:@[@(WARowPhone)]];
		[s addObject:@[@(WARowMedia), @(WARowMute), @(WARowBubbles)]];
		if (_blocked) [s addObject:@[@(WARowBlock)]];
	}
	_sections = s;
}

#pragma mark - Header: picture, name, status

- (UIView *)headerView {
	CGFloat w = self.view.bounds.size.width;
	UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 112)];
	h.backgroundColor = [UIColor clearColor];
	// profile frame
	UIView *frame = [[UIView alloc] initWithFrame:CGRectMake(10, 14, 80, 80)];
	frame.backgroundColor = [UIColor whiteColor];
	frame.layer.cornerRadius = 8;
	frame.layer.borderWidth = 1;
	frame.layer.borderColor = [UIColor colorWithWhite:0.6 alpha:1].CGColor;
	frame.layer.shadowColor = [UIColor whiteColor].CGColor;
	frame.layer.shadowOffset = CGSizeMake(0, 1);
	frame.layer.shadowOpacity = 1;
	frame.layer.shadowRadius = 0;
	[h addSubview:frame];
	_picture = [[UIImageView alloc] initWithFrame:CGRectInset(frame.bounds, 3, 3)];
	_picture.contentMode = UIViewContentModeScaleAspectFill;
	_picture.clipsToBounds = YES;
	_picture.layer.cornerRadius = 5;
	_picture.image = [[WAClient shared] cachedAvatarFor:_jid] ?: WAImg(_group ? @"GroupChat" : @"EmptyContact");
	_picture.userInteractionEnabled = YES;
	[_picture addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showPicture)]];
	[frame addSubview:_picture];
	[[WAClient shared] avatarFor:_jid completion:^(UIImage *image) {
		if (image) self->_picture.image = image;
	}];

	CGFloat x = 102, tw = w - x - 12;
	if (_group) {
		// tap pic to change, tap subject to edit
		[_picture removeGestureRecognizer:_picture.gestureRecognizers.firstObject];
		[_picture addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(groupPictureTapped)]];
		_subjectTable = [[UITableView alloc] initWithFrame:CGRectMake(x - 10, 4, tw + 20, 64) style:UITableViewStyleGrouped];
		_subjectTable.backgroundColor = [UIColor clearColor];
		_subjectTable.backgroundView = nil;
		_subjectTable.scrollEnabled = NO;
		_subjectTable.dataSource = self;
		_subjectTable.delegate = self;
		[h addSubview:_subjectTable];
	}
	_nameLabel = [self label:[UIFont boldSystemFontOfSize:19] color:WAColor(0x22272F) frame:CGRectMake(x, 18, tw, 24) in:h];
	_nameLabel.hidden = _group;
	_nameLabel.text = _name;
	_nameLabel.adjustsFontSizeToFitWidth = YES;
	_nameLabel.minimumScaleFactor = 0.7;
	_aboutLabel = [self label:[UIFont systemFontOfSize:14] color:WAColor(0x4C566C) frame:CGRectMake(x, 44, tw, 36) in:h];
	_aboutLabel.numberOfLines = 2;
	_subLabel = [self label:[UIFont systemFontOfSize:12] color:WAColor(0x7F8A99) frame:CGRectMake(x, 82, tw, 16) in:h];
	if (_group) _aboutLabel.frame = CGRectMake(x, 64, tw, 18);
	return h;
}

- (UILabel *)label:(UIFont *)font color:(UIColor *)color frame:(CGRect)frame in:(UIView *)view {
	UILabel *l = [[UILabel alloc] initWithFrame:frame];
	l.font = font;
	l.textColor = color;
	l.backgroundColor = [UIColor clearColor];
	l.shadowColor = [UIColor colorWithWhite:1 alpha:0.8];
	l.shadowOffset = CGSizeMake(0, 1);
	[view addSubview:l];
	return l;
}

- (void)fillHeader {
	if ([_info[@"name"] length]) _nameLabel.text = _info[@"name"];
	[_subjectTable reloadData];
	if (_group) self.tableView.tableFooterView = [self exitButton];
	if (_group) {
		NSMutableArray *parts = [NSMutableArray array];
		if ([_info[@"creator"] length]) [parts addObject:[NSString stringWithFormat:@"Created by %@", _info[@"creator"]]];
		if ([_info[@"created"] longLongValue] > 0) [parts addObject:WAShortTime([_info[@"created"] longLongValue])];
		_aboutLabel.text = [parts componentsJoinedByString:@", "];
		_subLabel.text = [NSString stringWithFormat:@"%lu participants", (unsigned long)[_info[@"participants"] count]];
	} else {
		NSString *about = _info[@"about"];
		_aboutLabel.text = about.length ? about : @"*** no status ***";
		_subLabel.text = [self presenceText:_info[@"presence"]];
	}
	// 2 line about
	CGSize s = [_aboutLabel.text sizeWithFont:_aboutLabel.font constrainedToSize:CGSizeMake(_aboutLabel.bounds.size.width, 36)];
	CGRect f = _aboutLabel.frame;
	f.size.height = MAX(18, ceilf(s.height));
	_aboutLabel.frame = f;
	CGRect sf = _subLabel.frame;
	sf.origin.y = CGRectGetMaxY(f) + 2;
	_subLabel.frame = sf;
}

- (NSString *)presenceText:(NSDictionary *)p {
	if (![p isKindOfClass:[NSDictionary class]]) return nil;
	if ([p[@"online"] boolValue]) return @"online";
	long long ts = [p[@"lastSeen"] longLongValue];
	return ts > 0 ? WALastSeen(ts) : nil;
}

- (void)showPicture {
	[WAMediaViewer showImageRequest:[[WAClient shared] fullAvatarRequestFor:_jid] placeholder:_picture.image from:self];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	if (tableView == _subjectTable) return 1;
	return _sections.count;
}

// admins can add/remove
- (BOOL)amAdmin {
	for (NSDictionary *p in _info[@"participants"]) if ([p[@"me"] boolValue]) return [p[@"admin"] boolValue];
	return NO;
}

- (NSInteger)memberOffset {
	return [self amAdmin] ? 1 : 0;
}

- (NSDictionary *)participantAt:(NSInteger)row {
	NSInteger i = row - [self memberOffset];
	NSArray *parts = _info[@"participants"];
	return i >= 0 && i < (NSInteger)parts.count ? parts[i] : nil;
}

- (WARow)rowKind:(NSIndexPath *)ip {
	return (WARow)[_sections[ip.section][0] integerValue] == WARowMember ? WARowMember
		: (WARow)[_sections[ip.section][ip.row] integerValue];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	if (tableView == _subjectTable) return 1;
	if ([_sections[section][0] integerValue] == WARowMember) return [_info[@"participants"] count] + [self memberOffset];
	return [_sections[section] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	if (tableView == _subjectTable) return nil;
	NSInteger first = [_sections[section][0] integerValue];
	if (first == WARowMember) {
		return [NSString stringWithFormat:@"Participants: %lu of %@", (unsigned long)[_info[@"participants"] count], @"1024"];
	}
	if (first == WARowPhone) return @"Phone Number";
	if (first == WARowTopic) return @"Group Description";
	return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
	if (tableView == _subjectTable) return 44;
	WARow kind = [self rowKind:indexPath];
	if (kind == WARowMember) return [self participantAt:indexPath.row] ? 52 : 44;
	if (kind == WARowTopic) {
		CGSize s = [_info[@"topic"] sizeWithFont:[UIFont systemFontOfSize:15] constrainedToSize:CGSizeMake(tableView.bounds.size.width - 60, 2000)];
		return MAX(44, ceilf(s.height) + 22);
	}
	return 44;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	if (tableView == _subjectTable) {
		UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
		cell.textLabel.text = [_info[@"name"] length] ? _info[@"name"] : _name;
		cell.textLabel.font = [UIFont boldSystemFontOfSize:17];
		cell.textLabel.adjustsFontSizeToFitWidth = YES;
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		return cell;
	}
	WARow kind = [self rowKind:indexPath];
	if (kind == WARowMember && ![self participantAt:indexPath.row]) {
		UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
		cell.textLabel.text = @"Add Participant...";
		cell.textLabel.textColor = WAColor(0x385487);
		cell.textLabel.textAlignment = NSTextAlignmentCenter;
		return cell;
	}
	if (kind == WARowMember) return [self memberCell:tableView row:indexPath.row];
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:kind == WARowPhone ? UITableViewCellStyleValue2
		: UITableViewCellStyleValue1 reuseIdentifier:nil];
	switch (kind) {
		case WARowPhone:
			cell.textLabel.text = @"mobile";
			cell.detailTextLabel.text = _info[@"phone"];
			break;
		case WARowTopic:
			cell.textLabel.text = _info[@"topic"];
			cell.textLabel.font = [UIFont systemFontOfSize:15];
			cell.textLabel.numberOfLines = 0;
			cell.selectionStyle = UITableViewCellSelectionStyleNone;
			break;
		case WARowMessage:
		case WARowCall:
			cell.textLabel.text = kind == WARowMessage ? @"Send Message" : @"Voice Call";
			cell.textLabel.textAlignment = NSTextAlignmentCenter;
			cell.textLabel.textColor = WAColor(0x385487);
			break;
		case WARowBlock:
			cell.textLabel.text = [_blocked boolValue] ? @"Unblock" : @"Block";
			cell.textLabel.textAlignment = NSTextAlignmentCenter;
			cell.textLabel.textColor = WAColor(0xC9302C);
			break;
		case WARowMedia:
			cell.textLabel.text = @"View All Media";
			cell.detailTextLabel.text = _info[@"media"] ? [_info[@"media"] description] : nil;
			cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
			break;
		case WARowFavorite:
			cell.textLabel.text = [WAFavoritesViewController isFavorite:_jid] ? @"Remove from Favorites" : @"Add to Favorites";
			cell.textLabel.textAlignment = NSTextAlignmentCenter;
			cell.textLabel.textColor = WAColor(0x385487);
			break;
		case WARowBubbles:
			cell.textLabel.text = @"Chat Bubbles";
			cell.detailTextLabel.text = WAChatBubble(_jid, YES) || WAChatBubble(_jid, NO) ? @"Custom" : @"Default";
			cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
			break;
		case WARowMute:
			cell.textLabel.text = _group ? @"Group Notifications" : @"Mute";
			cell.textLabel.adjustsFontSizeToFitWidth = YES;
			cell.detailTextLabel.text = [self muteText];
			cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
			break;
		default:
			break;
	}
	return cell;
}

- (NSString *)muteText {
	long long until = [_info[@"mutedUntil"] longLongValue];
	if (until == 0) return _group ? @"On" : @"Off";
	if (until < 0) return @"Muted";
	return [NSString stringWithFormat:@"Muted until %@", WAFutureTime(until)];
}

// member row
- (UITableViewCell *)memberCell:(UITableView *)tableView row:(NSInteger)row {
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"member"];
	if (!cell) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"member"];
		cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
		cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
		cell.detailTextLabel.textColor = WAColor(0x7F8A99);
		UILabel *admin = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 76, 20)];
		admin.font = [UIFont systemFontOfSize:13];
		admin.textColor = WAColor(0x7F8A99);
		admin.backgroundColor = [UIColor clearColor];
		admin.textAlignment = NSTextAlignmentRight;
		cell.accessoryView = admin;
	}
	NSDictionary *p = [self participantAt:row];
	cell.textLabel.text = p[@"name"];
	NSString *about = p[@"about"];
	cell.detailTextLabel.text = [p[@"me"] boolValue] ? nil : (about.length ? about : p[@"phone"]);
	((UILabel *)cell.accessoryView).text = [p[@"admin"] boolValue] ? @"group admin" : nil;
	cell.selectionStyle = [p[@"me"] boolValue] ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleBlue;
	NSString *jid = p[@"jid"];
	cell.imageView.image = [self thumb:[[WAClient shared] cachedAvatarFor:jid] ?: WAImg(@"EmptyContact")];
	[[WAClient shared] avatarFor:jid completion:^(UIImage *image) {
		NSIndexPath *ip = [tableView indexPathForCell:cell];
		if (image && ip && [[self participantAt:ip.row][@"jid"] isEqualToString:jid]) {
			cell.imageView.image = [self thumb:image];
		}
	}];
	return cell;
}

// 36pt rounded
- (UIImage *)thumb:(UIImage *)image {
	if (!image) return nil;
	CGRect r = CGRectMake(0, 0, 36, 36);
	UIGraphicsBeginImageContextWithOptions(r.size, NO, 0);
	[[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:4] addClip];
	CGFloat s = MAX(36 / image.size.width, 36 / image.size.height);
	CGSize d = CGSizeMake(image.size.width * s, image.size.height * s);
	[image drawInRect:CGRectMake((36 - d.width) / 2, (36 - d.height) / 2, d.width, d.height)];
	UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return out;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (tableView == _subjectTable) {
		[self editSubject];
		return;
	}
	switch ([self rowKind:indexPath]) {
		case WARowPhone: {
			UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:_info[@"phone"] delegate:self cancelButtonTitle:nil
				destructiveButtonTitle:nil otherButtonTitles:@"Voice Call", nil];
			if (WAVideoCallsEnabled()) [sheet addButtonWithTitle:@"Video Call"];
			[sheet addButtonWithTitle:@"Copy"];
			sheet.cancelButtonIndex = [sheet addButtonWithTitle:@"Cancel"];
			sheet.tag = 1;
			[sheet showInView:self.tabBarController.view ?: self.view];
			break;
		}
		case WARowMessage:
			[[NSNotificationCenter defaultCenter] postNotificationName:@"WAOpenChatNotification" object:nil
				userInfo:@{@"jid": _jid, @"name": _nameLabel.text ?: _name ?: @""}];
			break;
		case WARowCall:
			[[WACall shared] callJID:_jid name:_nameLabel.text];
			break;
		case WARowBlock: {
			BOOL unblock = [_blocked boolValue];
			NSString *text = unblock ? @"Tap “Unblock” to start receiving messages from contact." : @"Tap “Block” to stop receiving messages from contact.";
			UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:text delegate:self cancelButtonTitle:@"Cancel"
				destructiveButtonTitle:unblock ? nil : @"Block" otherButtonTitles:unblock ? @"Unblock" : nil, nil];
			sheet.tag = 3;
			[sheet showInView:self.tabBarController.view ?: self.view];
			break;
		}
		case WARowFavorite:
			[WAFavoritesViewController setFavorite:_jid on:![WAFavoritesViewController isFavorite:_jid]];
			[tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
			break;
		case WARowBubbles:
			[self.navigationController pushViewController:[[WABubbleColorsController alloc] initWithJID:_jid] animated:YES];
			break;
		case WARowMedia:
			[self.navigationController pushViewController:[[WAMediaViewController alloc] initWithChat:_jid
				title:@"All Media"] animated:YES];
			break;
		case WARowMute: {
			UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:@"Select Mute Interval" delegate:self
				cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:@"8 hours", @"1 week", @"1 year", nil];
			if ([_info[@"mutedUntil"] longLongValue] != 0) [sheet addButtonWithTitle:@"Unmute"];
			sheet.cancelButtonIndex = [sheet addButtonWithTitle:@"Cancel"];
			sheet.tag = 2;
			[sheet showInView:self.tabBarController.view ?: self.view];
			break;
		}
		case WARowMember: {
			NSDictionary *p = [self participantAt:indexPath.row];
			if (!p) {
				[self addParticipant];
				break;
			}
			if ([p[@"me"] boolValue]) break;
			// message / call / info / remove
			_selected = p;
			UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:p[@"name"] delegate:self cancelButtonTitle:nil
				destructiveButtonTitle:nil otherButtonTitles:@"Message", @"Call", @"Info", nil];
			if ([self amAdmin]) sheet.destructiveButtonIndex = [sheet addButtonWithTitle:[NSString stringWithFormat:@"Remove %@", p[@"name"]]];
			sheet.cancelButtonIndex = [sheet addButtonWithTitle:@"Cancel"];
			sheet.tag = 4;
			[sheet showInView:self.tabBarController.view ?: self.view];
			break;
		}
		default:
			break;
	}
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
	if (index == sheet.cancelButtonIndex) return;
	NSString *title = [sheet buttonTitleAtIndex:index];
	if (sheet.tag >= 4 && sheet.tag <= 7) {
		[self groupSheet:sheet clicked:index title:title];
		return;
	}
	if (sheet.tag == 3) {
		NSString *action = [title isEqualToString:@"Unblock"] ? @"unblock" : @"block";
		[[WAClient shared] post:@"/api/blocklist" params:@{@"jid": _jid, @"action": action} completion:^(id json, NSError *error) {
			if (error) {
				[[[UIAlertView alloc] initWithTitle:nil message:error.localizedDescription delegate:nil cancelButtonTitle:@"OK"
					otherButtonTitles:nil] show];
				return;
			}
			[self loadBlocked];
		}];
		return;
	}
	if (sheet.tag == 1) {
		if ([title isEqualToString:@"Voice Call"]) [[WACall shared] callJID:_jid name:_nameLabel.text];
		else if ([title isEqualToString:@"Video Call"]) [[WACall shared] callJID:_jid name:_nameLabel.text video:YES];
		else [UIPasteboard generalPasteboard].string = _info[@"phone"];
		return;
	}
	NSDictionary *hours = @{@"8 hours": @8, @"1 week": @168, @"1 year": @8760, @"Unmute": @0};
	if (!hours[title]) return;
	[[WAClient shared] post:@"/api/mute" params:@{@"chat": _jid, @"hours": hours[title]} completion:^(id json, NSError *error) {
		if (error) {
			[[[UIAlertView alloc] initWithTitle:nil message:error.localizedDescription delegate:nil
				cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
			return;
		}
		NSMutableDictionary *info = [self->_info mutableCopy];
		info[@"mutedUntil"] = json[@"mutedUntil"] ?: @0;
		self->_info = info;
		[self.tableView reloadData];
	}];
}

#pragma mark - Group: subject, picture, participants, exit (WhatsApp 2.10's GroupInfoViewController)

- (void)editSubject {
	WASubjectEditController *edit = [[WASubjectEditController alloc] initWithGroup:_jid subject:_info[@"name"] ?: _name];
	edit.onSaved = ^(NSString *subject) { [self load]; };
	[self presentViewController:[[UINavigationController alloc] initWithRootViewController:edit] animated:YES completion:nil];
}

- (void)groupPictureTapped {
	UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:@"Group Icon" delegate:self cancelButtonTitle:nil
		destructiveButtonTitle:nil otherButtonTitles:@"View", nil];
	if ([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) [sheet addButtonWithTitle:@"Take Photo"];
	[sheet addButtonWithTitle:@"Choose Existing Photo"];
	sheet.destructiveButtonIndex = [sheet addButtonWithTitle:@"Remove photo"];
	sheet.cancelButtonIndex = [sheet addButtonWithTitle:@"Cancel"];
	sheet.tag = 5;
	[sheet showInView:self.tabBarController.view ?: self.view];
}

- (void)addParticipant {
	WAPersonPicker *picker = [[WAPersonPicker alloc] init];
	picker.title = @"Add Participant";
	picker.onPick = ^(NSDictionary *c) {
		[[WAClient shared] post:@"/api/group/participants" params:@{@"jid": self->_jid, @"add": c[@"jid"]}
			completion:^(id json, NSError *error) {
				if (error || ![json[@"ok"] boolValue]) {
					NSString *msg = error ? error.localizedDescription
						: [NSString stringWithFormat:@"Failed to add %@ to the group “%@”.", c[@"name"], self->_info[@"name"] ?: self->_name];
					[[[UIAlertView alloc] initWithTitle:nil message:msg delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
				}
				[self load];
			}];
	};
	[self presentViewController:[[UINavigationController alloc] initWithRootViewController:picker] animated:YES completion:nil];
}

// red button
- (UIView *)exitButton {
	CGFloat w = self.view.bounds.size.width;
	UIView *f = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 74)];
	UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
	b.frame = CGRectMake(10, 10, w - 20, 44);
	UIImage *red = WAStretch(@"RedButton", 0, 10, 0, 10);
	[b setBackgroundImage:red forState:UIControlStateNormal];
	[b setBackgroundImage:WAStretch(@"RedButtonPressed", 0, 10, 0, 10) forState:UIControlStateHighlighted];
	if (!red) {
		b.backgroundColor = WAColor(0xC9302C);
		b.layer.cornerRadius = 8;
	}
	b.titleLabel.font = [UIFont boldSystemFontOfSize:18];
	b.titleLabel.shadowOffset = CGSizeMake(0, -1);
	[b setTitleShadowColor:[UIColor colorWithWhite:0 alpha:0.4] forState:UIControlStateNormal];
	[b setTitle:@"Delete and Exit Group" forState:UIControlStateNormal];
	[b addTarget:self action:@selector(exitGroupTapped) forControlEvents:UIControlEventTouchUpInside];
	[f addSubview:b];
	return f;
}

- (void)exitGroupTapped {
	UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:@"Cancel"
		destructiveButtonTitle:@"Delete and Exit Group" otherButtonTitles:nil];
	sheet.tag = 7;
	[sheet showInView:self.tabBarController.view ?: self.view];
}

- (void)alertError:(NSError *)error {
	[[[UIAlertView alloc] initWithTitle:nil message:error.localizedDescription delegate:nil cancelButtonTitle:@"OK"
		otherButtonTitles:nil] show];
}

- (void)groupSheet:(UIActionSheet *)sheet clicked:(NSInteger)index title:(NSString *)title {
	NSDictionary *p = _selected;
	if (sheet.tag == 4) {
		if ([title isEqualToString:@"Message"]) {
			[[NSNotificationCenter defaultCenter] postNotificationName:@"WAOpenChatNotification" object:nil
				userInfo:@{@"jid": p[@"jid"], @"name": p[@"name"] ?: @""}];
		} else if ([title isEqualToString:@"Call"]) {
			[[WACall shared] callJID:p[@"jid"] name:p[@"name"]];
		} else if ([title isEqualToString:@"Info"]) {
			[self.navigationController pushViewController:[[WAInfoViewController alloc] initWithJID:p[@"jid"] name:p[@"name"] group:NO]
				animated:YES];
		} else if (index == sheet.destructiveButtonIndex) {
			NSString *q = [NSString stringWithFormat:@"Remove %@ from “%@” group?", p[@"name"], _info[@"name"] ?: _name];
			UIActionSheet *confirm = [[UIActionSheet alloc] initWithTitle:q delegate:self cancelButtonTitle:@"Cancel"
				destructiveButtonTitle:@"Remove" otherButtonTitles:nil];
			confirm.tag = 6;
			[confirm showInView:self.tabBarController.view ?: self.view];
		}
	} else if (sheet.tag == 6) {
		[[WAClient shared] post:@"/api/group/participants" params:@{@"jid": _jid, @"remove": p[@"jid"]} completion:^(id json, NSError *error) {
			if (error || ![json[@"ok"] boolValue]) {
				[[[UIAlertView alloc] initWithTitle:nil message:@"Failed to remove participant." delegate:nil
					cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
			}
			[self load];
		}];
	} else if (sheet.tag == 5) {
		if ([title isEqualToString:@"View"]) {
			[self showPicture];
		} else if (index == sheet.destructiveButtonIndex) {
			[[WAClient shared] post:@"/api/group/photo" params:@{@"jid": _jid} data:[NSData data] contentType:@"image/jpeg"
				completion:^(id json, NSError *error) {
					if (error) [self alertError:error];
					else self->_picture.image = WAImg(@"GroupChat");
				}];
		} else {
			UIImagePickerController *picker = [[UIImagePickerController alloc] init];
			picker.sourceType = [title isEqualToString:@"Take Photo"] ? UIImagePickerControllerSourceTypeCamera
				: UIImagePickerControllerSourceTypePhotoLibrary;
			picker.allowsEditing = YES;
			picker.delegate = self;
			[self presentViewController:picker animated:YES completion:nil];
		}
	} else if (sheet.tag == 7) {
		[[WAClient shared] post:@"/api/group/leave" params:@{@"jid": _jid} completion:^(id json, NSError *error) {
			if (error) {
				[self alertError:error];
				return;
			}
			[self.navigationController popToRootViewControllerAnimated:YES];
		}];
	}
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
	UIImage *img = info[UIImagePickerControllerEditedImage] ?: info[UIImagePickerControllerOriginalImage];
	[picker dismissViewControllerAnimated:YES completion:nil];
	if (!img) return;
	[[WAClient shared] post:@"/api/group/photo" params:@{@"jid": _jid} data:UIImageJPEGRepresentation(img, 0.85)
		contentType:@"image/jpeg" completion:^(id json, NSError *error) {
			if (error) [self alertError:error];
			else self->_picture.image = img;
		}];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
	[picker dismissViewControllerAnimated:YES completion:nil];
}

@end
