#import <QuartzCore/QuartzCore.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import "WASettingsPages.h"
#import "WASettingsViewController.h"
#import "WAInfoViewController.h"
#import "WAClient.h"
#import "WAAssets.h"
#import "WAPrefs.h"
#import "WAUtil.h"
#import "WASetupViewController.h"
#import "WABubbles.h"
#import "WADiag.h"
#ifdef WA_DEV
#import "dev/WADev.h"
#endif

typedef void (^WAAction)(void);
typedef BOOL (^WAGetter)(void);
typedef void (^WASetter)(BOOL on);

@interface WATableController ()
- (NSDictionary *)rowAt:(NSIndexPath *)ip;
- (void)alert:(NSString *)text;
@end

#pragma mark - Table from data

@implementation WATableController

- (instancetype)init {
	return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self rebuild];
}

- (void)rebuild {
}

- (void)setSections:(NSArray *)sections {
	_sections = [sections copy];
	[self.tableView reloadData];
}

- (NSDictionary *)rowAt:(NSIndexPath *)ip {
	return self.sections[ip.section][@"rows"][ip.row];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return [self.sections[section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	return self.sections[section][@"header"];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	return self.sections[section][@"footer"];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
	NSNumber *h = [self rowAt:indexPath][@"height"];
	return h ? [h floatValue] : 44;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	NSDictionary *row = [self rowAt:indexPath];
	UITableViewCellStyle style = row[@"subtitle"] ? UITableViewCellStyleSubtitle : UITableViewCellStyleValue1;
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:nil];
	cell.textLabel.text = row[@"title"];
	cell.textLabel.adjustsFontSizeToFitWidth = YES;
	cell.detailTextLabel.text = row[@"subtitle"] ?: row[@"detail"];
	cell.imageView.image = row[@"image"];
	if ([row[@"disclosure"] boolValue]) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
	if ([row[@"check"] boolValue]) cell.accessoryType = UITableViewCellAccessoryCheckmark;
	if (row[@"button"]) {
		cell.textLabel.textAlignment = NSTextAlignmentCenter;
		cell.textLabel.textColor = [row[@"button"] isEqualToString:@"red"] ? WAColor(0xC9302C) : WAColor(0x385487);
	}
	if (row[@"switch"] || row[@"toggle"]) {
		UISwitch *sw = [[UISwitch alloc] init];
		sw.on = row[@"switch"] ? WAPrefBool(row[@"switch"]) : ((WAGetter)row[@"on"])();
		sw.tag = indexPath.section * 1000 + indexPath.row;
		[sw addTarget:self action:@selector(switched:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = sw;
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
	} else if (!row[@"action"]) {
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
	}
	return cell;
}

- (void)switched:(UISwitch *)sw {
	NSDictionary *row = self.sections[sw.tag / 1000][@"rows"][sw.tag % 1000];
	if (row[@"switch"]) WASetPref(row[@"switch"], @(sw.on));
	else ((WASetter)row[@"toggle"])(sw.on);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	WAAction action = [self rowAt:indexPath][@"action"];
	if (action) action();
}

- (void)alert:(NSString *)text {
	[[[UIAlertView alloc] initWithTitle:nil message:text delegate:nil cancelButtonTitle:WAL(@"OK") otherButtonTitles:nil] show];
}

@end

// pick from list (sounds)
@interface WAChoiceController : WATableController
- (instancetype)initWithTitle:(NSString *)title options:(NSArray *)options key:(NSString *)key;
@end

@implementation WAChoiceController {
	NSArray *_options;
	NSString *_key;
}

- (instancetype)initWithTitle:(NSString *)title options:(NSArray *)options key:(NSString *)key {
	if ((self = [super init])) {
		self.title = title;
		_options = options;
		_key = key;
	}
	return self;
}

- (void)rebuild {
	NSString *current = WAPrefString(_key), *key = _key;
	NSMutableArray *rows = [NSMutableArray array];
	__weak WAChoiceController *weak = self;
	for (NSString *o in _options) {
		[rows addObject:@{@"title": WAL(o), @"check": @([o isEqualToString:current]), @"action": ^{
			WASetPref(key, o);
			WAPlaySound(o);
			[weak rebuild];
		}}];
	}
	self.sections = @[@{@"rows": rows}];
}

@end

#pragma mark - Notifications

@interface WANotificationsController : WATableController
@end

@implementation WANotificationsController

- (void)rebuild {
	self.title = WAL(@"Notifications");
	__weak WANotificationsController *weak = self;
	WAAction (^sound)(NSString *, NSString *) = ^WAAction(NSString *title, NSString *key) {
		return [^{
			[weak.navigationController pushViewController:[[WAChoiceController alloc] initWithTitle:title options:WASoundNames()
				key:key] animated:YES];
		} copy];
	};
	self.sections = @[
		@{@"header": WAL(@"Message Notifications"), @"rows": @[
			@{@"title": WAL(@"Alerts"), @"switch": WAPrefMessageAlerts},
			@{@"title": WAL(@"Sound"), @"detail": WAL(WAPrefString(WAPrefMessageSound)) ?: @"", @"disclosure": @YES,
				@"action": sound(WAL(@"Sound"), WAPrefMessageSound)}]},
		@{@"header": WAL(@"Group Notifications"), @"footer": WAL(@"You can set custom group notifications in the Group Info page for a specific group"),
			@"rows": @[
			@{@"title": WAL(@"Alerts"), @"switch": WAPrefGroupAlerts},
			@{@"title": WAL(@"Sound"), @"detail": WAL(WAPrefString(WAPrefGroupSound)) ?: @"", @"disclosure": @YES,
				@"action": sound(WAL(@"Sound"), WAPrefGroupSound)}]},
		@{@"rows": @[@{@"title": WAL(@"In-App Sounds"), @"switch": WAPrefInAppSounds},
			@{@"title": WAL(@"In-App Vibrate"), @"switch": WAPrefInAppVibrate},
			@{@"title": WAL(@"In-App Preview"), @"switch": WAPrefInAppPreview}]},
		@{@"footer": WAL(@"Preview message text inside new message notifications."), @"rows": @[
			@{@"title": WAL(@"Show Preview"), @"switch": WAPrefShowPreview}]},
		@{@"footer": WAL(@"Reset all notification settings including custom group notifications."), @"rows": @[
			@{@"title": WAL(@"Reset All Notifications"), @"button": @"blue", @"action": ^{
				for (NSString *k in @[WAPrefMessageAlerts, WAPrefMessageSound, WAPrefGroupAlerts, WAPrefGroupSound, WAPrefShowPreview,
					WAPrefInAppSounds, WAPrefInAppVibrate, WAPrefInAppPreview]) WASetPref(k, nil);
				[weak rebuild];
			}}]},
	];
}

@end

#pragma mark - Chat Settings

@interface WABlockedController : WATableController
@end

@implementation WABlockedController {
	NSArray *_blocked;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = WAL(@"Blocked");
	[self load];
}

- (void)load {
	[[WAClient shared] get:@"/api/blocklist" params:nil completion:^(id json, NSError *error) {
		self->_blocked = [json[@"blocked"] isKindOfClass:[NSArray class]] ? json[@"blocked"] : @[];
		[self rebuild];
	}];
}

- (void)rebuild {
	NSMutableArray *rows = [NSMutableArray array];
	__weak WABlockedController *weak = self;
	for (NSDictionary *c in _blocked) {
		[rows addObject:@{@"title": c[@"name"] ?: @"", @"subtitle": c[@"phone"] ?: @"", @"disclosure": @YES, @"action": ^{
			[weak.navigationController pushViewController:[[WAInfoViewController alloc] initWithJID:c[@"jid"] name:c[@"name"]
				group:NO] animated:YES];
		}}];
	}
	self.sections = @[@{@"footer": WAL(@"Blocked contacts will no longer be able to send you messages, but can still see your status."),
		@"rows": rows}];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	if (_blocked) [self load];
}

@end

// pick a value
@interface WAOptionController : WATableController
- (instancetype)initWithTitle:(NSString *)title key:(NSString *)key values:(NSArray *)values titles:(NSArray *)titles
	footer:(NSString *)footer;
@end

@implementation WAOptionController {
	NSString *_key, *_footer;
	NSArray *_values, *_titles;
}

- (instancetype)initWithTitle:(NSString *)title key:(NSString *)key values:(NSArray *)values titles:(NSArray *)titles
	footer:(NSString *)footer {
	if ((self = [super init])) {
		self.title = title;
		_key = key;
		_values = values;
		_titles = titles;
		_footer = footer;
	}
	return self;
}

- (void)rebuild {
	NSString *current = WAPrefString(_key), *key = _key;
	NSMutableArray *rows = [NSMutableArray array];
	__weak WAOptionController *weak = self;
	[_values enumerateObjectsUsingBlock:^(NSString *v, NSUInteger i, BOOL *stop) {
		[rows addObject:@{@"title": self->_titles[i], @"check": @([v isEqualToString:current]), @"action": ^{
			WASetPref(key, v);
			[weak rebuild];
		}}];
	}];
	self.sections = @[_footer ? @{@"rows": rows, @"footer": _footer} : @{@"rows": rows}];
}

@end

// auto-download + optimize video
@interface WAAutoDownloadController : WATableController
@end

static NSArray *NetworkValues(void) { return @[@"never", @"wifi", @"all"]; }
static NSArray *NetworkTitles(void) { return @[WAL(@"Never"), WAL(@"Wi-Fi"), WAL(@"Wi-Fi and Cellular")]; }
static NSString *TitleFor(NSString *key, NSArray *values, NSArray *titles) {
	NSUInteger i = [values indexOfObject:WAPrefString(key) ?: @""];
	return i == NSNotFound ? titles[0] : titles[i];
}

@implementation WAAutoDownloadController

- (void)rebuild {
	self.title = WAL(@"Auto-Download");
	__weak WAAutoDownloadController *weak = self;
	NSMutableArray *media = [NSMutableArray array];
	for (NSArray *k in @[@[@"Photos", WAPrefAutoPhotos], @[@"Audio", WAPrefAutoAudio], @[@"Videos", WAPrefAutoVideos]]) {
		NSString *title = k[0], *key = k[1];
		[media addObject:@{@"title": title, @"detail": TitleFor(key, NetworkValues(), NetworkTitles()), @"disclosure": @YES,
			@"action": ^{
				[weak.navigationController pushViewController:[[WAOptionController alloc] initWithTitle:title key:key
					values:NetworkValues() titles:NetworkTitles() footer:nil] animated:YES];
			}}];
	}
	self.sections = @[
		@{@"header": WAL(@"Auto-Download Media"), @"rows": media,
			@"footer": WAL(@"Previews stay small. Wi-Fi loads the best quality; cellular data uses optimized media when opened.")},
	];
}

@end

#pragma mark - Custom Bubbles

@implementation WABubbleColorsController {
	NSString *_jid;
}

- (instancetype)initWithJID:(NSString *)jid {
	if ((self = [super init])) _jid = [jid copy];
	return self;
}

- (NSArray *)rowsMine:(BOOL)mine {
	NSString *jid = _jid;
	NSString *current = jid ? WAChatBubble(jid, mine) : WAPrefString(mine ? WAPrefBubbleOut : WAPrefBubbleIn);
	__weak WABubbleColorsController *weak = self;
	NSMutableArray *rows = [NSMutableArray array];
	if (jid) {
		NSString *def = WAPrefString(mine ? WAPrefBubbleOut : WAPrefBubbleIn);
		[rows addObject:@{@"title": WAL(@"Default"), @"detail": WAL(def), @"image": WABubbleSwatch(def, mine), @"check": @(current == nil),
			@"height": @44, @"action": ^{
				WASetChatBubble(jid, mine, nil);
				[weak rebuild];
			}}];
	}
	for (NSString *name in WABubbleColorNames()) {
		[rows addObject:@{@"title": WAL(name), @"image": WABubbleSwatch(name, mine), @"check": @([name isEqualToString:current]),
			@"action": ^{
				if (jid) WASetChatBubble(jid, mine, name);
				else WASetPref(mine ? WAPrefBubbleOut : WAPrefBubbleIn, name);
				[weak rebuild];
			}}];
	}
	return rows;
}

- (void)rebuild {
	self.title = WAL(@"Chat Bubbles");
	self.sections = @[
		@{@"header": WAL(@"Your Messages"), @"rows": [self rowsMine:YES]},
		@{@"header": WAL(@"Their Messages"), @"rows": [self rowsMine:NO],
			@"footer": _jid ? WAL(@"These colors are only used in this chat.") : WAL(@"You can also pick colors for a single chat in its Contact Info or Group Info.")},
	];
}

@end

@interface WAAdvancedController : WATableController
@property (nonatomic, copy) NSString *lastSeen;
@end

@implementation WAAdvancedController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = WAL(@"Advanced");
	[[WAClient shared] get:@"/api/me" params:nil completion:^(id json, NSError *error) {
		self.lastSeen = json[@"lastSeen"];
		[self rebuild];
	}];
}

- (void)rebuild {
	__weak WAAdvancedController *weak = self;
	NSMutableArray *sections = [NSMutableArray arrayWithObject:@{@"footer": WAL(@"Choose which media is downloaded automatically."),
		@"rows": @[@{@"title": WAL(@"Auto-Download"), @"disclosure": @YES, @"action": ^{
			[weak.navigationController pushViewController:[[WAAutoDownloadController alloc] init] animated:YES];
		}}]}];
	if (self.lastSeen) {
		[sections addObject:@{@"footer": WAL(@"Turn OFF to not allow or show last seen timestamp."), @"rows": @[
			@{@"title": WAL(@"Last Seen Timestamp"), @"on": ^BOOL { return ![weak.lastSeen isEqualToString:@"none"]; },
				@"toggle": ^(BOOL on) {
					// back to what it was, not simply everyone
					NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
					if (!on && ![weak.lastSeen isEqualToString:@"none"]) [d setObject:weak.lastSeen forKey:@"lastSeenBeforeOff"];
					NSString *value = on ? ([d stringForKey:@"lastSeenBeforeOff"] ?: @"contacts") : @"none";
					[[WAClient shared] post:@"/api/me/lastseen" params:@{@"value": value} completion:^(id json, NSError *error) {
						if (error) [weak alert:error.localizedDescription];
						else if (json[@"lastSeen"]) weak.lastSeen = json[@"lastSeen"];
						[weak rebuild];
					}];
				}}]}];
	}
	[sections addObject:@{@"footer": [WAL(WADiagWhat) stringByAppendingString:WAL(@" Never messages, contacts, numbers, names, your IP or location. Turning it off deletes what was sent.")],
		@"rows": @[@{@"title": WAL(@"Send Diagnostics"), @"on": ^BOOL { return WAPrefBool(WAPrefDiagnostics); },
			@"toggle": ^(BOOL on) {
				if (on) [[WADiag shared] turnedOn];
				else {
					NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
					[d setBool:YES forKey:@"diagAsked"];
					[d setBool:NO forKey:WAPrefDiagnostics];
					[[WADiag shared] turnedOff];
				}
			}}]}];
	self.sections = sections;
}

@end

// wallpaper: 2.10 library, photos, reset
@interface WAWallpaperController : WATableController <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@end

@interface WAWallpaperLibraryController : UIViewController
@end

static NSString *WallpaperDir(void) {
	return WAAssetPath(@"Wallpaper");
}

static NSString *OwnWallpaperPath(void) {
	return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library"] stringByAppendingPathComponent:@"wallpaper.jpg"];
}

@implementation WAWallpaperLibraryController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = WAL(@"Wallpaper Library");
	self.view.backgroundColor = [UIColor blackColor];
	UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
	scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[self.view addSubview:scroll];
	NSArray *files = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:WallpaperDir() error:NULL]
		sortedArrayUsingSelector:@selector(compare:)];
	CGFloat gap = 4, w = floorf((self.view.bounds.size.width - gap * 4) / 3), h = floorf(w * 1.5f);
	NSInteger i = 0;
	for (NSString *f in files) {
		NSString *path = [WallpaperDir() stringByAppendingPathComponent:f];
		UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
		b.frame = CGRectMake(gap + (i % 3) * (w + gap), gap + (i / 3) * (h + gap), w, h);
		b.imageView.contentMode = UIViewContentModeScaleAspectFill;
		b.clipsToBounds = YES;
		b.accessibilityLabel = path;
		[b setImage:[UIImage imageWithContentsOfFile:path] forState:UIControlStateNormal];
		[b addTarget:self action:@selector(pick:) forControlEvents:UIControlEventTouchUpInside];
		[scroll addSubview:b];
		i++;
	}
	scroll.contentSize = CGSizeMake(self.view.bounds.size.width, gap + ((i + 2) / 3) * (h + gap));
}

- (void)pick:(UIButton *)b {
	WASetPref(WAPrefWallpaper, b.accessibilityLabel);
	[self.navigationController popViewControllerAnimated:YES];
}

@end

@implementation WAWallpaperController

- (void)rebuild {
	self.title = WAL(@"Chat Wallpaper");
	__weak WAWallpaperController *weak = self;
	self.sections = @[
		@{@"rows": @[
			@{@"title": WAL(@"Wallpaper Library"), @"disclosure": @YES, @"action": ^{
				[weak.navigationController pushViewController:[[WAWallpaperLibraryController alloc] init] animated:YES];
			}},
			@{@"title": WAL(@"Photo Library"), @"disclosure": @YES, @"action": ^{
				UIImagePickerController *picker = [[UIImagePickerController alloc] init];
				picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
				picker.delegate = weak;
				[weak presentViewController:picker animated:YES completion:nil];
			}}]},
		@{@"rows": @[@{@"title": WAL(@"Reset Wallpaper"), @"button": @"blue", @"action": ^{
			WASetPref(WAPrefWallpaper, nil);
			[weak.navigationController popViewControllerAnimated:YES];
		}}]},
	];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
	UIImage *img = info[UIImagePickerControllerOriginalImage];
	[picker dismissViewControllerAnimated:YES completion:nil];
	if (!img) return;
	[UIImageJPEGRepresentation(img, 0.8) writeToFile:OwnWallpaperPath() atomically:YES];
	WASetPref(WAPrefWallpaper, OwnWallpaperPath());
	[self.navigationController popViewControllerAnimated:YES];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
	[picker dismissViewControllerAnimated:YES completion:nil];
}

@end

@interface WAChatSettingsController : WATableController
@end

@implementation WAChatSettingsController {
	NSNumber *_blockedCount;
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[[WAClient shared] get:@"/api/blocklist" params:nil completion:^(id json, NSError *error) {
		if ([json[@"blocked"] isKindOfClass:[NSArray class]]) self->_blockedCount = @([json[@"blocked"] count]);
		[self rebuild];
	}];
}

- (void)rebuild {
	self.title = WAL(@"Chat Settings");
	__weak WAChatSettingsController *weak = self;
	WAAction (^push)(Class) = ^WAAction(Class cls) {
		return [^{ [weak.navigationController pushViewController:[[cls alloc] init] animated:YES]; } copy];
	};
	NSString *blocked = _blockedCount ? [NSString stringWithFormat:@"%@ %@", _blockedCount, [_blockedCount intValue] == 1 ? WAL(@"contact") : WAL(@"contacts")] : @"";
	self.sections = @[
		@{@"footer": WAL(@"List of contacts you have blocked."), @"rows": @[
			@{@"title": WAL(@"Blocked"), @"detail": blocked, @"disclosure": @YES, @"action": push([WABlockedController class])}]},
		@{@"rows": @[@{@"title": WAL(@"Chat Wallpaper"), @"disclosure": @YES, @"action": push([WAWallpaperController class])},
			@{@"title": WAL(@"Chat Bubbles"), @"disclosure": @YES, @"action": push([WABubbleColorsController class])}]},
		@{@"footer": WAL(@"Display time when message was sent or received."), @"rows": @[
			@{@"title": WAL(@"Message Timestamp"), @"switch": WAPrefMessageTimestamp}]},
		@{@"footer": WAL(@"Automatically save images and video that you receive into the Camera Roll."), @"rows": @[
			@{@"title": WAL(@"Save Incoming Media"), @"switch": WAPrefSaveIncomingMedia}]},
		@{@"footer": WAL(@"Edit advanced chat settings."), @"rows": @[
			@{@"title": WAL(@"Advanced"), @"disclosure": @YES, @"action": push([WAAdvancedController class])}]},
	];
}

@end

#pragma mark - Profile

@interface WAProfileController : WATableController <UIActionSheetDelegate, UIImagePickerControllerDelegate,
	UINavigationControllerDelegate>
@end

@implementation WAProfileController {
	NSDictionary *_me;
	UIImageView *_photo;
	UITextField *_nameField;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = WAL(@"Profile");
	self.tableView.tableHeaderView = [self photoHeader];
	_nameField = [self field:WAL(@"Your name")];
	[self load];
}

- (void)load {
	[[WAClient shared] get:@"/api/me" params:nil completion:^(id json, NSError *error) {
		if (![json isKindOfClass:[NSDictionary class]]) return;
		self->_me = json;
		self->_nameField.text = json[@"pushName"];
		[self loadPhoto];
	}];
}

- (void)loadPhoto {
	NSString *jid = _me[@"jid"];
	if (!jid) return;
	[[WAClient shared] load:[[WAClient shared] fullAvatarRequestFor:jid] completion:^(NSData *data, NSInteger status, NSError *error) {
		UIImage *img = status == 200 ? [UIImage imageWithData:data] : nil;
		self->_photo.image = img ?: WAImg(@"EmptyContact");
	}];
}

// photo frame with edit strip
- (UIView *)photoHeader {
	CGFloat w = self.view.bounds.size.width;
	UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 142)];
	UIImage *frameImage = WAImg(@"ProfilePicEditPhoto");
	CGFloat side = frameImage ? frameImage.size.width : 100;
	UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
	b.frame = CGRectMake(floorf((w - side) / 2), 18, side, side);
	[b addTarget:self action:@selector(photoTapped) forControlEvents:UIControlEventTouchUpInside];
	_photo = [[UIImageView alloc] initWithFrame:CGRectInset(b.bounds, 4, 4)];
	_photo.contentMode = UIViewContentModeScaleAspectFill;
	_photo.clipsToBounds = YES;
	_photo.layer.cornerRadius = 4;
	_photo.image = WAImg(@"EmptyContact");
	[b addSubview:_photo];
	UIImageView *frame = [[UIImageView alloc] initWithFrame:b.bounds];
	frame.image = frameImage;
	[b addSubview:frame];
	if (!frame.image) {
		b.layer.borderWidth = 1;
		b.layer.borderColor = [UIColor colorWithWhite:0.6 alpha:1].CGColor;
		b.layer.cornerRadius = 6;
	}
	UILabel *edit = [[UILabel alloc] initWithFrame:CGRectMake(4, b.bounds.size.height - 23, b.bounds.size.width - 8, 18)];
	edit.text = WAL(@"edit");
	edit.font = [UIFont boldSystemFontOfSize:12];
	edit.textColor = [UIColor whiteColor];
	edit.backgroundColor = [UIColor clearColor];
	edit.textAlignment = NSTextAlignmentCenter;
	[b addSubview:edit];
	[h addSubview:b];
	return h;
}

- (UITextField *)field:(NSString *)placeholder {
	UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 280, 24)];
	f.placeholder = placeholder;
	f.font = [UIFont systemFontOfSize:16];
	f.enabled = NO; // setting it fails too often, the phone does it
	return f;
}

- (void)rebuild {
	self.sections = @[
		@{@"header": WAL(@"Push name"), @"footer": WAL(@"To change your name, open WhatsApp on your phone."), @"rows": @[@{@"field": _nameField}]},
	];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
	UITextField *f = [self rowAt:indexPath][@"field"];
	f.frame = CGRectMake(10, 10, cell.contentView.bounds.size.width - 40, 24);
	f.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[cell.contentView addSubview:f];
	return cell;
}

- (void)photoTapped {
	UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:WAL(@"Profile Photo") delegate:self cancelButtonTitle:nil
		destructiveButtonTitle:nil otherButtonTitles:nil];
	if ([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) [sheet addButtonWithTitle:WAL(@"Take Photo")];
	[sheet addButtonWithTitle:WAL(@"Choose Existing Photo")];
	sheet.destructiveButtonIndex = [sheet addButtonWithTitle:WAL(@"Delete Photo")];
	sheet.cancelButtonIndex = [sheet addButtonWithTitle:WAL(@"Cancel")];
	[sheet showInView:self.tabBarController.view ?: self.view];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
	if (index == sheet.cancelButtonIndex) return;
	if (index == sheet.destructiveButtonIndex) {
		[self upload:[NSData data]];
		return;
	}
	UIImagePickerController *picker = [[UIImagePickerController alloc] init];
	picker.sourceType = [[sheet buttonTitleAtIndex:index] isEqualToString:WAL(@"Take Photo")] ? UIImagePickerControllerSourceTypeCamera
		: UIImagePickerControllerSourceTypePhotoLibrary;
	picker.allowsEditing = YES; // square crop
	picker.delegate = self;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
	UIImage *img = info[UIImagePickerControllerEditedImage] ?: info[UIImagePickerControllerOriginalImage];
	[picker dismissViewControllerAnimated:YES completion:nil];
	if (!img) return;
	_photo.image = img;
	[self upload:UIImageJPEGRepresentation(img, 0.85)];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
	[picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)upload:(NSData *)jpeg {
	[UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
	[[WAClient shared] post:@"/api/me/photo" params:nil data:jpeg contentType:@"image/jpeg" completion:^(id json, NSError *error) {
		[UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
		if (error) [self alert:WAL(@"Sorry, could not update your profile photo.")];
		else [[WAClient shared] forgetAvatar:self->_me[@"jid"]];
		[self loadPhoto];
	}];
}

@end

#pragma mark - Account

@interface WAAccountController : WATableController <UIActionSheetDelegate>
@end

@implementation WAAccountController {
	NSDictionary *_me;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = WAL(@"Account");
	self.tableView.tableFooterView = [self logOutButton];
	[[WAClient shared] get:@"/api/me" params:nil completion:^(id json, NSError *error) {
		if ([json isKindOfClass:[NSDictionary class]]) self->_me = json;
		[self rebuild];
	}];
}

- (void)rebuild {
	__weak WAAccountController *weak = self;
	self.sections = @[
		@{@"header": WAL(@"Phone Number"), @"rows": @[@{@"title": _me[@"phone"] ?: @"…"}]},
		@{@"header": WAL(@"Linked Device"),
			@"footer": WAL(@"This iPhone is a linked device of your WhatsApp account. Messages reach it through your own WA Classic bridge; your phone does not need to stay online."),
			@"rows": @[@{@"title": WAL(@"Device"), @"detail": [NSString stringWithFormat:@"%@ · WA Classic", [UIDevice currentDevice].model]},
				@{@"title": WAL(@"Device Number"), @"detail": _me[@"device"] ? [_me[@"device"] description] : @"…"},
				@{@"title": WAL(@"Connection"), @"detail": _me ? ([_me[@"connected"] boolValue] ? WAL(@"Connected") : WAL(@"Not connected")) : @"…"}]},
		@{@"rows": @[@{@"title": WAL(@"Network Status"), @"disclosure": @YES, @"action": ^{
			[weak.navigationController pushViewController:[[WASettingsViewController alloc] init] animated:YES];
		}}]},
	];
}

// log out button
- (UIView *)logOutButton {
	UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 70)];
	UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
	b.frame = CGRectMake(10, 10, 300, 41);
	b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
	UIImage *red = WAImg(@"RedButton"), *pressed = WAImg(@"RedButtonPressed");
	if (red) {
		CGFloat cap = floorf(red.size.width / 2);
		[b setBackgroundImage:[red resizableImageWithCapInsets:UIEdgeInsetsMake(0, cap, 0, cap)] forState:UIControlStateNormal];
		[b setBackgroundImage:[pressed resizableImageWithCapInsets:UIEdgeInsetsMake(0, cap, 0, cap)] forState:UIControlStateHighlighted];
	} else {
		b.backgroundColor = WAColor(0xC9302C);
		b.layer.cornerRadius = 8;
	}
	[b setTitle:WAL(@"Log Out") forState:UIControlStateNormal];
	b.titleLabel.font = [UIFont fontWithName:@"Helvetica-Bold" size:18];
	b.titleLabel.shadowOffset = CGSizeMake(0, -1);
	[b setTitleShadowColor:[UIColor colorWithWhite:0 alpha:0.4] forState:UIControlStateNormal];
	[b addTarget:self action:@selector(logOutTapped) forControlEvents:UIControlEventTouchUpInside];
	[v addSubview:b];
	return v;
}

- (void)logOutTapped {
	UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:WAL(@"This logs out every iPhone on your bridge, not just this one. Their chats will be deleted there; your phone keeps them. To use WA Classic again, link again, with any account.")
		delegate:self cancelButtonTitle:WAL(@"Cancel") destructiveButtonTitle:WAL(@"Log Out") otherButtonTitles:nil];
	[sheet showFromTabBar:self.tabBarController.tabBar];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
	if (index != sheet.destructiveButtonIndex) return;
	[UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
	[[WAClient shared] post:@"/api/pair/unlink" params:nil completion:^(id json, NSError *error) {
		[UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
		if (error) {
			[self alert:WAL(@"WhatsApp requires an active internet connection to update your settings.")];
			return;
		}
		WALog(@"account: logged out");
		[self.navigationController popToRootViewControllerAnimated:NO];
		[[NSNotificationCenter defaultCenter] postNotificationName:WALinkNeededNotification object:nil];
	}];
}

@end

#pragma mark - Root

@implementation WASettingsRootViewController {
	NSDictionary *_me;
	UIImage *_photo;
	NSString *_network;
}

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
		self.title = WAL(@"Settings");
		self.tabBarItem = [[UITabBarItem alloc] initWithTitle:WAL(@"Settings") image:WAImg(@"Settings") tag:4];
	}
	return self;
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	if (![WAClient shared].configured) {
		_network = WAL(@"Not set up");
		[self.tableView reloadData];
		return;
	}
	[[WAClient shared] get:@"/api/me" params:nil completion:^(id json, NSError *error) {
		self->_network = error ? WAL(@"Not connected") : ([json[@"connected"] boolValue] ? WAL(@"Connected") : WAL(@"Connecting"));
		if ([json isKindOfClass:[NSDictionary class]]) {
			self->_me = json;
			[[WAClient shared] avatarFor:json[@"jid"] completion:^(UIImage *image) {
				self->_photo = image;
				[self.tableView reloadData];
			}];
		}
		[self.tableView reloadData];
	}];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
#ifdef WA_DEV
	return 5;
#endif
	return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return section == 1 ? 4 : section == 3 ? 2 : 1;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
	return indexPath.section == 0 ? 64 : 44;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	if (section != 3) return nil;
	NSString *v = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
	return [NSString stringWithFormat:WAL(@"WA Classic %@ by aronsz26 – an unofficial WhatsApp client for iOS 4 to 6, linked to your account through your own bridge. Not affiliated with WhatsApp or Meta."), v];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:indexPath.section == 0 ? UITableViewCellStyleSubtitle
		: UITableViewCellStyleValue1 reuseIdentifier:nil];
	cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
	switch (indexPath.section) {
		case 0: {
			cell.textLabel.text = [_me[@"pushName"] length] ? _me[@"pushName"] : WAL(@"Profile");
			cell.textLabel.font = [UIFont boldSystemFontOfSize:18];
			cell.detailTextLabel.text = _me[@"phone"];
			UIImage *pic = _photo ?: WAImg(@"EmptyContact");
			if (pic) {
				UIGraphicsBeginImageContextWithOptions(CGSizeMake(48, 48), NO, 0);
				[[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 48, 48) cornerRadius:5] addClip];
				[pic drawInRect:CGRectMake(0, 0, 48, 48)];
				cell.imageView.image = UIGraphicsGetImageFromCurrentImageContext();
				UIGraphicsEndImageContext();
			}
			break;
		}
		case 1:
			// "Languages" stays english, so it can be found in any language
			cell.textLabel.text = @[WAL(@"Account"), WAL(@"Chat Settings"), WAL(@"Notifications"), @"Languages"][indexPath.row];
			if (indexPath.row == 3) cell.detailTextLabel.text = WAChosenLanguage() ? WALanguageName(WAChosenLanguage()) : WAL(@"Automatic");
			break;
		case 2:
			cell.textLabel.text = WAL(@"Network Status");
			cell.detailTextLabel.text = _network;
			break;
#ifdef WA_DEV
		case 4:
			cell.textLabel.text = @"Debug";
			break;
#endif
		default:
			cell.textLabel.text = indexPath.row ? WAL(@"Help & Bugs") : WAL(@"Tell a Friend");
			break;
	}
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	UIViewController *next = nil;
	switch (indexPath.section) {
		case 0: next = [[WAProfileController alloc] init]; break;
		case 1: next = [@[[WAAccountController class], [WAChatSettingsController class], [WANotificationsController class],
			[WALanguagesController class]][indexPath.row] new]; break;
		case 2: next = [[WASettingsViewController alloc] init]; break;
#ifdef WA_DEV
		case 4: next = WADevMenu(); break;
#endif
		default:
			if (indexPath.row) {
				// Discord doesn't load in old Safari, so hand out the link
				[UIPasteboard generalPasteboard].string = @"https://discord.gg/HaTErjRdbk";
				[[[UIAlertView alloc] initWithTitle:WAL(@"Help & Bugs") message:WAL(@"Ask questions and report bugs on the WA Classic Discord. The link was copied, open it on a computer or a newer phone:\n\ndiscord.gg/HaTErjRdbk") delegate:nil
					cancelButtonTitle:WAL(@"OK") otherButtonTitles:nil] show];
				return;
			}
			[UIPasteboard generalPasteboard].string = WAL(@"WhatsApp Messenger is available for iPhone, Android, Nokia, BlackBerry and Windows Phone.");
			[[[UIAlertView alloc] initWithTitle:WAL(@"Tell a Friend") message:WAL(@"The invitation text was copied.") delegate:nil
				cancelButtonTitle:WAL(@"OK") otherButtonTitles:nil] show];
			return;
	}
	[self.navigationController pushViewController:next animated:YES];
}

@end

#pragma mark - Languages

NSString *const WALanguageChangedNotification = @"WALanguageChangedNotification";

@implementation WALanguagesController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Languages";
	[self rebuild];
}

- (void)rebuild {
	NSString *chosen = WAChosenLanguage();
	NSArray *codes = [WASupportedLanguages() sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
		return [WALanguageName(a) localizedCaseInsensitiveCompare:WALanguageName(b)];
	}];
	NSMutableArray *rows = [NSMutableArray array];
	__weak WALanguagesController *weak = self;
	for (NSString *code in codes) {
		[rows addObject:@{@"title": WALanguageName(code), @"check": @([code isEqualToString:chosen]), @"action": ^{ [weak pick:code]; }}];
	}
	self.sections = @[
		@{@"rows": @[@{@"title": WAL(@"Automatic"), @"check": @(chosen == nil), @"action": ^{ [weak pick:nil]; }}],
			@"footer": WAL(@"Automatic uses the language of your iPhone, or English if WA Classic doesn't support it.")},
		@{@"rows": rows}];
}

- (void)pick:(NSString *)code {
	if ((code == nil && WAChosenLanguage() == nil) || [code isEqualToString:WAChosenLanguage()]) return;
	WALog(@"settings: language %@", code ?: @"automatic");
	WASetLanguage(code);
	[[NSNotificationCenter defaultCenter] postNotificationName:WALanguageChangedNotification object:nil];
}

@end
