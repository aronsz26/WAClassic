#import <QuartzCore/QuartzCore.h>
#import "WACallsViewController.h"
#import "../WACall.h"
#import "../WAClient.h"
#import "../WAAssets.h"
#import "../WAInfoViewController.h"
#import "../WAPersonPicker.h"
#import "../WAUtil.h"

static NSString *const kHiddenKey = @"callsHidden", *const kClearedKey = @"callsClearedTS", *const kSeenKey = @"callsSeenTS";

#pragma mark - Graphics

static NSString *const kAnswer = @"/System/Library/PrivateFrameworks/TelephonyUI.framework/answer";

// handset for the tab bar, only the alpha counts there
static UIImage *TabGlyph(void) {
	UIImage *glyph = WASystemImg(kAnswer);
	if (!glyph) return nil;
	CGSize size = CGSizeMake(30, 30);
	UIGraphicsBeginImageContextWithOptions(size, NO, 0);
	[glyph drawInRect:CGRectMake(2, 3, 26, 24.7f)];
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

// handset with a plus, new call
static UIImage *NewCallGlyph(void) {
	UIImage *glyph = WASystemImg(kAnswer);
	if (!glyph) return nil;
	CGSize size = CGSizeMake(27, 21);
	UIGraphicsBeginImageContextWithOptions(size, NO, 0);
	[glyph drawInRect:CGRectMake(0, 2, 20, 19)];
	[[UIColor whiteColor] setFill];
	UIRectFill(CGRectMake(19, 3, 8, 2));
	UIRectFill(CGRectMake(22, 0, 2, 8));
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

// same glyphs as the call pills in a chat
static UIImage *DirectionGlyph(BOOL mine, BOOL missed) {
	static NSCache *cache;
	if (!cache) cache = [[NSCache alloc] init];
	NSString *key = mine ? @"out" : (missed ? @"missed" : @"in");
	UIImage *img = [cache objectForKey:key];
	if (img) return img;
	UIImage *src = WASystemImg(mine ? @"/Applications/MobilePhone.app/outgoingcall" : @"/Applications/MobilePhone.app/activecall");
	if (!src) return nil;
	if (mine) {
		img = src;
	} else {
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

static NSString *OutcomeTitle(NSDictionary *call) {
	NSString *outcome = call[@"text"];
	if ([outcome isEqualToString:@"missed"]) return @"Missed";
	if ([outcome isEqualToString:@"declined"]) return @"Declined";
	if ([outcome isEqualToString:@"elsewhere"]) return @"On another device";
	if ([outcome isEqualToString:@"cancelled"]) return @"Cancelled";
	if ([outcome isEqualToString:@"unanswered"]) return @"No answer";
	return [call[@"fromMe"] boolValue] ? @"Outgoing" : @"Incoming";
}

#pragma mark - Cell

@interface WACallCell : UITableViewCell
@property (nonatomic, strong) UIImageView *avatar, *direction;
@property (nonatomic, strong) UILabel *nameLabel, *timeLabel, *detailLabel;
@property (nonatomic, copy) NSString *jid;
@end

@implementation WACallCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
	if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
		self.accessoryType = UITableViewCellAccessoryDetailDisclosureButton;
		_avatar = [[UIImageView alloc] init];
		_avatar.contentMode = UIViewContentModeScaleAspectFill;
		_avatar.clipsToBounds = YES;
		_avatar.layer.cornerRadius = 4;
		[self.contentView addSubview:_avatar];
		_direction = [[UIImageView alloc] init];
		_direction.contentMode = UIViewContentModeCenter;
		[self.contentView addSubview:_direction];
		_nameLabel = [self label:[UIFont boldSystemFontOfSize:17] color:[UIColor blackColor]];
		_timeLabel = [self label:[UIFont systemFontOfSize:14] color:WAColor(0x2470D8)];
		_timeLabel.textAlignment = NSTextAlignmentRight;
		_detailLabel = [self label:[UIFont systemFontOfSize:15] color:WAColor(0x7F7F7F)];
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

// like a chat row
- (void)layoutSubviews {
	[super layoutSubviews];
	CGFloat w = self.contentView.bounds.size.width;
	self.avatar.frame = CGRectMake(6, 6, 52, 52);
	CGFloat x = 66;
	CGSize time = [self.timeLabel.text sizeWithFont:self.timeLabel.font];
	self.timeLabel.frame = CGRectMake(w - time.width - 4, 10, time.width, 18);
	self.nameLabel.frame = CGRectMake(x, 9, w - x - time.width - 10, 21);
	self.direction.frame = CGRectMake(x, 35, 14, 16);
	self.detailLabel.frame = CGRectMake(x + 18, 33, w - x - 22, 20);
}

@end

#pragma mark - List

@implementation WACallsViewController {
	NSArray *_calls;        // nil = not loaded yet
	NSMutableArray *_rows;  // @{ids, count, call}, next to each other = one row like the phone app
	UISegmentedControl *_filter;
	UIView *_empty;
	UIBarButtonItem *_newItem, *_clearItem;
	BOOL _loading;
}

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStylePlain])) {
		self.title = @"Calls";
		self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Calls" image:TabGlyph() tag:1];
		NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
		[nc addObserver:self selector:@selector(updatesArrived:) name:WAClientUpdatesNotification object:nil];
		[nc addObserver:self selector:@selector(reload) name:WAClientServerChangedNotification object:nil];
		[nc addObserver:self selector:@selector(reloadIfShowing) name:UIApplicationDidBecomeActiveNotification object:nil];
	}
	return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.tableView.rowHeight = 64;
	self.tableView.allowsSelectionDuringEditing = NO;
	_filter = [[UISegmentedControl alloc] initWithItems:@[@"All", @"Missed"]];
	_filter.segmentedControlStyle = UISegmentedControlStyleBar;
	_filter.selectedSegmentIndex = 0;
	_filter.frame = CGRectMake(0, 0, 150, 30);
	[_filter addTarget:self action:@selector(filterChanged) forControlEvents:UIControlEventValueChanged];
	self.navigationItem.titleView = _filter;
	self.navigationItem.leftBarButtonItem = self.editButtonItem;
	_newItem = [[UIBarButtonItem alloc] initWithImage:NewCallGlyph() style:UIBarButtonItemStyleBordered
		target:self action:@selector(newCall)];
	_clearItem = [[UIBarButtonItem alloc] initWithTitle:@"Clear" style:UIBarButtonItemStyleBordered
		target:self action:@selector(askClear)];
	self.navigationItem.rightBarButtonItem = _newItem;
	[self buildRows];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self reload];
	[self markSeen];
}

- (void)viewDidDisappear:(BOOL)animated {
	[super viewDidDisappear:animated];
	if (self.editing) [self setEditing:NO animated:NO];
}

- (BOOL)showing {
	return self.isViewLoaded && self.view.window != nil;
}

- (void)reloadIfShowing {
	if ([self showing]) [self reload];
}

- (void)updatesArrived:(NSNotification *)note {
	if (!_calls) {
		[self reload];
		return;
	}
	for (NSDictionary *m in note.userInfo[@"messages"]) {
		if ([m[@"kind"] isEqualToString:@"call"]) {
			[self reload];
			return;
		}
	}
}

- (void)reload {
	if (_loading || ![WAClient shared].configured) return;
	_loading = YES;
	[[WAClient shared] get:@"/api/calls" params:nil completion:^(id json, NSError *error) {
		self->_loading = NO;
		// bridge too old or away: keep what we have
		if (![json isKindOfClass:[NSDictionary class]] || ![json[@"calls"] isKindOfClass:[NSArray class]]) {
			if (!self->_calls) [self buildRows];
			return;
		}
		self->_calls = json[@"calls"];
		[self buildRows];
		if ([self showing]) [self markSeen];
		else [self updateBadge];
	}];
}

#pragma mark - Rows

- (NSArray *)visibleCalls {
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	NSSet *hidden = [NSSet setWithArray:[d arrayForKey:kHiddenKey] ?: @[]];
	long long cleared = [[d objectForKey:kClearedKey] longLongValue];
	NSMutableArray *out = [NSMutableArray array];
	for (NSDictionary *call in _calls) {
		if ([call[@"ts"] longLongValue] <= cleared || [hidden containsObject:call[@"id"]]) continue;
		[out addObject:call];
	}
	return out;
}

- (void)buildRows {
	if (self.editing && _rows.count) return; // not under the user's finger
	BOOL missedOnly = _filter.selectedSegmentIndex == 1;
	_rows = [NSMutableArray array];
	NSMutableDictionary *last = nil;
	for (NSDictionary *call in [self visibleCalls]) {
		if (missedOnly && ![call[@"text"] isEqualToString:@"missed"]) continue;
		NSDictionary *first = last[@"call"];
		if (first && [first[@"peer"] isEqualToString:call[@"peer"]] && [OutcomeTitle(first) isEqualToString:OutcomeTitle(call)]) {
			[last[@"ids"] addObject:call[@"id"]];
			continue;
		}
		last = [@{@"call": call, @"ids": [NSMutableArray arrayWithObject:call[@"id"]]} mutableCopy];
		[_rows addObject:last];
	}
	if (self.isViewLoaded) {
		[self.tableView reloadData];
		[self updateEmpty];
	}
}

- (void)updateEmpty {
	BOOL none = _calls && _rows.count == 0;
	self.tableView.separatorStyle = none ? UITableViewCellSeparatorStyleNone : UITableViewCellSeparatorStyleSingleLine;
	if (!none) {
		self.tableView.tableFooterView = [[UIView alloc] init];
		return;
	}
	if (!_empty) {
		CGFloat w = self.view.bounds.size.width;
		_empty = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 220)];
		UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 90, w - 40, 24)];
		title.font = [UIFont boldSystemFontOfSize:19];
		title.tag = 1;
		UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(30, 118, w - 60, 40)];
		hint.font = [UIFont systemFontOfSize:15];
		hint.numberOfLines = 2;
		hint.tag = 2;
		for (UILabel *l in @[title, hint]) {
			l.textColor = WAColor(0x7F8A99);
			l.textAlignment = NSTextAlignmentCenter;
			l.backgroundColor = [UIColor clearColor];
			l.shadowColor = [UIColor whiteColor];
			l.shadowOffset = CGSizeMake(0, 1);
			[_empty addSubview:l];
		}
	}
	BOOL missed = _filter.selectedSegmentIndex == 1;
	[(UILabel *)[_empty viewWithTag:1] setText:missed ? @"No Missed Calls" : @"No Recent Calls"];
	[(UILabel *)[_empty viewWithTag:2] setText:missed ? nil : @"Tap the phone at the top to call one of your contacts."];
	self.tableView.tableFooterView = _empty;
}

- (void)filterChanged {
	if (self.editing) [self setEditing:NO animated:NO]; // rows are frozen while editing
	[self buildRows];
}

#pragma mark - Missed badge

- (void)markSeen {
	long long newest = 0;
	for (NSDictionary *call in _calls) newest = MAX(newest, [call[@"ts"] longLongValue]);
	if (newest) {
		NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
		[d setObject:@(newest) forKey:kSeenKey];
		[d synchronize];
	}
	self.tabBarItem.badgeValue = nil;
}

- (void)updateBadge {
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	NSNumber *seen = [d objectForKey:kSeenKey];
	// first start: old calls aren't news
	if (!seen) {
		[self markSeen];
		return;
	}
	NSUInteger missed = 0;
	for (NSDictionary *call in [self visibleCalls]) {
		if ([call[@"text"] isEqualToString:@"missed"] && [call[@"ts"] longLongValue] > seen.longLongValue) missed++;
	}
	self.tabBarItem.badgeValue = missed ? [@(missed) description] : nil;
}

#pragma mark - Actions

- (void)newCall {
	WAPersonPicker *picker = [[WAPersonPicker alloc] init];
	picker.title = @"New Call";
	picker.onPick = ^(NSDictionary *c) {
		[[WACall shared] callJID:c[@"jid"] name:c[@"name"] video:NO];
	};
	[self presentViewController:[[UINavigationController alloc] initWithRootViewController:picker] animated:YES completion:nil];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
	[super setEditing:editing animated:animated];
	[self.navigationItem setRightBarButtonItem:editing ? _clearItem : _newItem animated:animated];
	if (!editing) [self buildRows];
}

- (void)askClear {
	UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:@"Cancel"
		destructiveButtonTitle:@"Clear All Calls" otherButtonTitles:nil];
	[sheet showInView:self.tabBarController.view ?: self.view];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
	if (index != sheet.destructiveButtonIndex) return;
	long long newest = 0;
	for (NSDictionary *call in _calls) newest = MAX(newest, [call[@"ts"] longLongValue]);
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	[d setObject:@(newest) forKey:kClearedKey];
	[d removeObjectForKey:kHiddenKey];
	[d synchronize];
	[self setEditing:NO animated:YES];
}

- (void)devCommand:(NSString *)what {
	if ([what isEqualToString:@"all"] || [what isEqualToString:@"missed"]) {
		_filter.selectedSegmentIndex = [what isEqualToString:@"missed"] ? 1 : 0;
		[self filterChanged];
	} else if ([what isEqualToString:@"new"]) {
		[self newCall];
	} else if ([what isEqualToString:@"edit"]) {
		[self setEditing:!self.editing animated:YES];
	}
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return _rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	WACallCell *cell = [tableView dequeueReusableCellWithIdentifier:@"call"];
	if (!cell) cell = [[WACallCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"call"];
	NSDictionary *row = _rows[indexPath.row], *call = row[@"call"];
	NSString *jid = call[@"peer"];
	NSUInteger count = [row[@"ids"] count];
	BOOL mine = [call[@"fromMe"] boolValue], missed = [call[@"text"] isEqualToString:@"missed"];
	cell.jid = jid;
	NSString *name = [call[@"name"] length] ? call[@"name"] : jid;
	cell.nameLabel.text = count > 1 ? [NSString stringWithFormat:@"%@ (%lu)", name, (unsigned long)count] : name;
	cell.nameLabel.textColor = missed ? WAColor(0xD12F2F) : [UIColor blackColor];
	cell.timeLabel.text = WAShortTime([call[@"ts"] longLongValue]);
	cell.direction.image = DirectionGlyph(mine, missed);
	NSString *detail = OutcomeTitle(call);
	NSInteger secs = [call[@"secs"] integerValue];
	if (count == 1 && [call[@"text"] isEqualToString:@"answered"]) {
		detail = secs >= 3600
			? [NSString stringWithFormat:@"%@ · %ld:%02ld:%02ld", detail, (long)(secs / 3600), (long)(secs / 60 % 60), (long)(secs % 60)]
			: [NSString stringWithFormat:@"%@ · %ld:%02ld", detail, (long)(secs / 60), (long)(secs % 60)];
	}
	cell.detailLabel.text = detail;
	cell.avatar.image = [[WAClient shared] cachedAvatarFor:jid] ?: WAImg(@"EmptyContact");
	[[WAClient shared] avatarFor:jid completion:^(UIImage *image) {
		if (image && [cell.jid isEqualToString:jid]) cell.avatar.image = image;
	}];
	[cell setNeedsLayout];
	return cell;
}

// tap = call back, like the phone app
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	NSDictionary *call = _rows[indexPath.row][@"call"];
	[[WACall shared] callJID:call[@"peer"] name:call[@"name"] video:NO];
}

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {
	NSDictionary *call = _rows[indexPath.row][@"call"];
	[self.navigationController pushViewController:[[WAInfoViewController alloc] initWithJID:call[@"peer"] name:call[@"name"] group:NO]
		animated:YES];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
	if (style != UITableViewCellEditingStyleDelete) return;
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	NSMutableArray *hidden = [[d arrayForKey:kHiddenKey] mutableCopy] ?: [NSMutableArray array];
	[hidden addObjectsFromArray:_rows[indexPath.row][@"ids"]];
	[d setObject:hidden forKey:kHiddenKey];
	[d synchronize];
	[_rows removeObjectAtIndex:indexPath.row];
	[tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
	if (!_rows.count) [self updateEmpty];
}

@end
