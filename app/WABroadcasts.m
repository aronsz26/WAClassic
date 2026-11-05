#import <QuartzCore/QuartzCore.h>
#import "WABroadcasts.h"
#import "WANewGroupViewController.h"
#import "WAInfoViewController.h"
#import "WAClient.h"
#import "WACall.h"
#import "WAAssets.h"
#import "WAUtil.h"

static NSString *RecipientsText(NSDictionary *b) {
	NSUInteger n = [b[@"recipients"] count];
	return [NSString stringWithFormat:n == 1 ? @"%lu recipient" : @"%lu recipients", (unsigned long)n];
}

static NSString *BroadcastText(NSDictionary *b) {
	NSString *text = b[@"text"];
	if ([b[@"kind"] isEqualToString:@"image"]) return text.length ? [@"Photo: " stringByAppendingString:text] : @"Photo";
	return text;
}

// new broadcast = group composer in broadcast mode
static void Compose(UINavigationController *nav, UIViewController *presenter) {
	WANewGroupViewController *composer = [[WANewGroupViewController alloc] init];
	composer.broadcast = YES;
	composer.onBroadcastSent = ^(NSDictionary *b) {
		[nav pushViewController:[[WABroadcastViewController alloc] initWithBroadcast:b] animated:YES];
	};
	[presenter presentViewController:[[UINavigationController alloc] initWithRootViewController:composer] animated:YES completion:nil];
}

#pragma mark - Broadcasts

@implementation WABroadcastListViewController {
	NSArray *_broadcasts;
}

+ (void)openFrom:(UIViewController *)from {
	[[WAClient shared] get:@"/api/broadcasts" params:nil completion:^(id json, NSError *error) {
		NSArray *list = [json[@"broadcasts"] isKindOfClass:[NSArray class]] ? json[@"broadcasts"] : @[];
		if (list.count) {
			WABroadcastListViewController *vc = [[WABroadcastListViewController alloc] initWithStyle:UITableViewStylePlain];
			vc->_broadcasts = list;
			[from.navigationController pushViewController:vc animated:YES];
		} else {
			Compose(from.navigationController, from);
		}
	}];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Broadcasts";
	self.tableView.rowHeight = 64;
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
		target:self action:@selector(add)];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[[WAClient shared] get:@"/api/broadcasts" params:nil completion:^(id json, NSError *error) {
		if (![json[@"broadcasts"] isKindOfClass:[NSArray class]]) return;
		self->_broadcasts = json[@"broadcasts"];
		[self.tableView reloadData];
	}];
}

- (void)add {
	Compose(self.navigationController, self);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return _broadcasts.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"b"];
	UILabel *time;
	if (!cell) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"b"];
		cell.textLabel.font = [UIFont boldSystemFontOfSize:17];
		cell.detailTextLabel.font = [UIFont systemFontOfSize:14];
		cell.detailTextLabel.textColor = WAColor(0x7F8A99);
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		time = [[UILabel alloc] initWithFrame:CGRectMake(tableView.bounds.size.width - 110, 8, 80, 16)];
		time.tag = 9;
		time.font = [UIFont systemFontOfSize:14];
		time.textColor = WAColor(0x2470D8);
		time.textAlignment = NSTextAlignmentRight;
		time.backgroundColor = [UIColor clearColor];
		[cell.contentView addSubview:time];
	}
	time = (UILabel *)[cell.contentView viewWithTag:9];
	NSDictionary *b = _broadcasts[indexPath.row];
	cell.imageView.image = WAImg(@"BrdtChatListIcon");
	cell.textLabel.text = RecipientsText(b);
	cell.detailTextLabel.text = BroadcastText(b);
	time.text = WAShortTime([b[@"ts"] longLongValue]);
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	[self.navigationController pushViewController:[[WABroadcastViewController alloc] initWithBroadcast:_broadcasts[indexPath.row]]
		animated:YES];
}

// only deletes it here
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
	if (style != UITableViewCellEditingStyleDelete) return;
	NSDictionary *b = _broadcasts[indexPath.row];
	NSMutableArray *left = [_broadcasts mutableCopy];
	[left removeObjectAtIndex:indexPath.row];
	_broadcasts = left;
	[tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
	[[WAClient shared] post:@"/api/broadcasts" params:@{@"delete": [b[@"id"] description]} completion:^(id json, NSError *error) {}];
}

@end

#pragma mark - One broadcast

@implementation WABroadcastViewController {
	NSDictionary *_broadcast;
	NSDictionary *_selected;
	UIImageView *_photo;
}

- (instancetype)initWithBroadcast:(NSDictionary *)broadcast {
	if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
		_broadcast = broadcast;
		self.title = @"Broadcast";
	}
	return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	UIImage *rebroadcast = WAImg(@"BrdtRebroadcast");
	self.navigationItem.rightBarButtonItem = rebroadcast
		? [[UIBarButtonItem alloc] initWithImage:rebroadcast style:UIBarButtonItemStyleBordered target:self action:@selector(rebroadcast)]
		: [[UIBarButtonItem alloc] initWithTitle:@"Resend" style:UIBarButtonItemStyleBordered target:self action:@selector(rebroadcast)];
	self.tableView.tableHeaderView = [self messageArea];
	// ticks come via long poll
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:WAClientUpdatesNotification object:nil];
	[self refresh];
}

- (void)refresh {
	[[WAClient shared] get:@"/api/broadcasts" params:@{@"id": _broadcast[@"id"] ?: @0} completion:^(id json, NSError *error) {
		if (![json[@"recipients"] isKindOfClass:[NSArray class]]) return;
		self->_broadcast = json;
		[self.tableView reloadData];
	}];
}

// header: bubble on chat bg + divider
- (UIView *)messageArea {
	CGFloat w = self.view.bounds.size.width;
	BOOL photo = [_broadcast[@"kind"] isEqualToString:@"image"];
	NSString *text = _broadcast[@"text"] ?: @"";
	UIFont *font = [UIFont systemFontOfSize:16];
	CGSize ts = text.length ? [text sizeWithFont:font constrainedToSize:CGSizeMake(200, 200) lineBreakMode:NSLineBreakByWordWrapping]
		: CGSizeZero;
	ts = CGSizeMake(ceilf(ts.width), ceilf(ts.height));
	CGFloat cw = MAX(photo ? 200 : ts.width, 40), ch = (photo ? 150 + (text.length ? 4 : 0) : 0) + ts.height;
	CGSize bs = CGSizeMake(cw + 31, MAX(ch, 20) + 15);
	CGFloat areaH = MAX(124, bs.height + 30);
	UIView *area = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, areaH + 7)];
	area.backgroundColor = WAColor(0xECE4DE);
	CGRect bubble = CGRectMake(w - bs.width - 10, floorf((areaH - bs.height) / 2), bs.width, bs.height);
	UIImageView *bv = [[UIImageView alloc] initWithFrame:bubble];
	bv.image = WAStretch(@"BroadcastBubbleOut", 10, 15, 19, 24);
	if (!bv.image) {
		bv.backgroundColor = WAColor(0xD6E6F7);
		bv.layer.cornerRadius = 12;
	}
	[area addSubview:bv];
	CGFloat y = bubble.origin.y + 6;
	if (photo) {
		_photo = [[UIImageView alloc] initWithFrame:CGRectMake(bubble.origin.x + 7, y, 206, 150)];
		_photo.contentMode = UIViewContentModeScaleAspectFill;
		_photo.clipsToBounds = YES;
		_photo.layer.cornerRadius = 5;
		_photo.backgroundColor = [UIColor colorWithWhite:0.85 alpha:1];
		[area addSubview:_photo];
		NSNumber *seq = [_broadcast[@"recipients"] count] ? _broadcast[@"recipients"][0][@"seq"] : nil;
		if (seq) {
			[[WAClient shared] load:[[WAClient shared] mediaRequestForSeq:[seq longLongValue] format:nil]
				completion:^(NSData *data, NSInteger status, NSError *e) {
					UIImage *img = status == 200 ? [UIImage imageWithData:data] : nil;
					if (img) self->_photo.image = img;
				}];
		}
		y += 154;
	}
	if (text.length) {
		UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(bubble.origin.x + 10, y, ts.width, ts.height)];
		l.text = text;
		l.font = font;
		l.numberOfLines = 0;
		l.backgroundColor = [UIColor clearColor];
		[area addSubview:l];
	}
	// time + megaphone
	UILabel *time = [[UILabel alloc] init];
	time.text = WAClockTime([_broadcast[@"ts"] longLongValue]);
	time.font = [UIFont italicSystemFontOfSize:11];
	time.textColor = WAColor(0x4D5866);
	time.backgroundColor = [UIColor clearColor];
	[time sizeToFit];
	time.frame = CGRectMake(bubble.origin.x - time.bounds.size.width - 6, CGRectGetMaxY(bubble) - 19, time.bounds.size.width, 14);
	[area addSubview:time];
	UIImageView *icon = [[UIImageView alloc] initWithImage:WAImg(@"BroadcastStatusIcon")];
	icon.frame = CGRectMake(time.frame.origin.x - 16, time.frame.origin.y, 13, 13);
	[area addSubview:icon];
	// divider shadow
	UIView *divider = [[UIView alloc] initWithFrame:CGRectMake(0, areaH, w, 7)];
	CAGradientLayer *g = [CAGradientLayer layer];
	g.frame = divider.bounds;
	g.colors = @[(id)[UIColor colorWithWhite:0 alpha:0.25].CGColor, (id)[UIColor colorWithWhite:0 alpha:0].CGColor];
	[divider.layer addSublayer:g];
	[area addSubview:divider];
	return area;
}

- (void)rebroadcast {
	self.navigationItem.rightBarButtonItem.enabled = NO;
	[[WAClient shared] post:@"/api/broadcast/resend" params:@{@"id": [_broadcast[@"id"] description]} completion:^(id json, NSError *error) {
		self.navigationItem.rightBarButtonItem.enabled = YES;
		if (error || ![json[@"broadcast"] isKindOfClass:[NSDictionary class]]) {
			[[[UIAlertView alloc] initWithTitle:@"Not sent" message:error.localizedDescription delegate:nil
				cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
			return;
		}
		// replace this page with the new one
		UINavigationController *nav = self.navigationController;
		NSMutableArray *stack = [nav.viewControllers mutableCopy];
		[stack replaceObjectAtIndex:stack.count - 1 withObject:[[WABroadcastViewController alloc] initWithBroadcast:json[@"broadcast"]]];
		[nav setViewControllers:stack animated:YES];
	}];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return [_broadcast[@"recipients"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	return RecipientsText(_broadcast);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
	NSDictionary *r = _broadcast[@"recipients"][indexPath.row];
	cell.textLabel.text = [r[@"name"] length] ? r[@"name"] : r[@"jid"];
	cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
	// grey ticks
	int status = [r[@"status"] intValue];
	UIImage *tick = status >= 2 ? WAImg(@"BrdtDoubleCheck") : (status == 1 ? WAImg(@"BrdtCheck") : WAImg(@"GrayClockIcon"));
	if (tick) cell.accessoryView = [[UIImageView alloc] initWithImage:tick];
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	_selected = _broadcast[@"recipients"][indexPath.row];
	UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:_selected[@"name"] delegate:self cancelButtonTitle:nil
		destructiveButtonTitle:nil otherButtonTitles:@"Message", @"Call", @"Info", nil];
	sheet.cancelButtonIndex = [sheet addButtonWithTitle:@"Cancel"];
	[sheet showInView:self.tabBarController.view ?: self.view];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
	if (index == sheet.cancelButtonIndex || !_selected) return;
	NSString *jid = _selected[@"jid"], *name = _selected[@"name"] ?: @"";
	NSString *choice = [sheet buttonTitleAtIndex:index];
	if ([choice isEqualToString:@"Message"]) {
		[[NSNotificationCenter defaultCenter] postNotificationName:@"WAOpenChatNotification" object:nil
			userInfo:@{@"jid": jid, @"name": name}];
	} else if ([choice isEqualToString:@"Call"]) {
		[[WACall shared] callJID:jid name:name];
	} else {
		[self.navigationController pushViewController:[[WAInfoViewController alloc] initWithJID:jid name:name group:NO] animated:YES];
	}
}

@end
