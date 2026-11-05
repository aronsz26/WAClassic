#import <QuartzCore/QuartzCore.h>
#import "WANewGroupViewController.h"
#import "WAClient.h"
#import "WAAssets.h"
#import "WAUtil.h"

static const NSInteger kMaxSubject = 25;
static const NSUInteger kMaxRecipients = 50;

#pragma mark - Contact picker (PeoplePickerView.nib: search bar, check marks, Cancel / Done in a toolbar)

@implementation WAPeoplePickerController {
	UITableView *_table;
	UISearchBar *_search;
	NSArray *_shown;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"WhatsApp Contacts";
	CGRect b = self.view.bounds;
	_search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, b.size.width, 44)];
	_search.placeholder = @"Search";
	_search.delegate = self;
	_search.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[self.view addSubview:_search];
	_table = [[UITableView alloc] initWithFrame:CGRectMake(0, 44, b.size.width, b.size.height - 88) style:UITableViewStylePlain];
	_table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_table.dataSource = self;
	_table.delegate = self;
	_table.rowHeight = 48;
	[self.view addSubview:_table];
	UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, b.size.height - 44, b.size.width, 44)];
	bar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
	UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
	UIBarButtonItem *cancel = [[UIBarButtonItem alloc] initWithTitle:@"Cancel" style:UIBarButtonItemStyleBordered target:self action:@selector(cancel)];
	UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:@"Done" style:UIBarButtonItemStyleDone target:self action:@selector(done)];
	cancel.width = done.width = 130;
	bar.items = @[flex, cancel, flex, done, flex];
	[self.view addSubview:bar];
	[self filter];
}

- (void)filter {
	NSString *q = _search.text.lowercaseString;
	if (!q.length) {
		_shown = self.contacts;
	} else {
		NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *c, NSDictionary *bindings) {
			return [[c[@"name"] lowercaseString] rangeOfString:q].location != NSNotFound;
		}];
		_shown = [self.contacts filteredArrayUsingPredicate:p];
	}
	[_table reloadData];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
	[self filter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
	[searchBar resignFirstResponder];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return _shown.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
	if (!cell) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
		cell.textLabel.font = [UIFont boldSystemFontOfSize:17];
		cell.detailTextLabel.textColor = WAColor(0x7F8A99);
	}
	NSDictionary *c = _shown[indexPath.row];
	cell.textLabel.text = c[@"name"];
	cell.detailTextLabel.text = c[@"phone"];
	cell.accessoryType = [self.selected containsObject:c[@"jid"]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	NSString *jid = _shown[indexPath.row][@"jid"];
	if ([self.selected containsObject:jid]) [self.selected removeObject:jid];
	else [self.selected addObject:jid];
	[tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)cancel {
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (void)done {
	if (self.onDone) self.onDone(self.selected);
	[self dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - New Group

@interface WANewGroupViewController () <UITextFieldDelegate, UITextViewDelegate, UITableViewDataSource, UITableViewDelegate,
	UIActionSheetDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@end

@implementation WANewGroupViewController {
	NSArray *_contacts;
	NSMutableArray *_participants; // in order added
	UIView *_participantsRow, *_subjectRow, *_iconRow;
	UIView *_tokens;
	UITextField *_searchField, *_subjectField;
	UILabel *_countLabel;
	UITableView *_results;
	NSArray *_matches;
	UIButton *_iconButton;
	UIImage *_icon;
	BOOL _creating;
	UIView *_messageRow, *_attachRow;
	UITextView *_messageView;
	UILabel *_messagePlaceholder, *_hint;
	UIButton *_photoButton;
	UIImage *_photo;
	BOOL _pickingPhoto; // picker is for the broadcast photo
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = self.broadcast ? @"New Broadcast" : @"New Group";
	self.view.backgroundColor = [UIColor whiteColor];
	_participants = [NSMutableArray array];
	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
		target:self action:@selector(cancel)];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:self.broadcast ? @"Send" : @"Create"
		style:UIBarButtonItemStyleDone target:self action:self.broadcast ? @selector(sendBroadcast) : @selector(create)];
	self.navigationItem.rightBarButtonItem.enabled = NO;
	CGFloat w = self.view.bounds.size.width;

	// participants row
	_participantsRow = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 44)];
	_participantsRow.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[_participantsRow addSubview:[self fieldLabel:self.broadcast ? @"To:" : @"Participants:"]];
	_tokens = [[UIView alloc] init];
	[_participantsRow addSubview:_tokens];
	_searchField = [[UITextField alloc] init];
	_searchField.font = [UIFont systemFontOfSize:15];
	_searchField.autocorrectionType = UITextAutocorrectionTypeNo;
	_searchField.delegate = self;
	[_searchField addTarget:self action:@selector(searchChanged) forControlEvents:UIControlEventEditingChanged];
	[_participantsRow addSubview:_searchField];
	UIButton *add = [UIButton buttonWithType:UIButtonTypeContactAdd];
	add.frame = CGRectMake(w - 38, 7, 30, 30);
	add.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
	[add addTarget:self action:@selector(pickContacts) forControlEvents:UIControlEventTouchUpInside];
	[_participantsRow addSubview:add];
	[self.view addSubview:_participantsRow];

	// subject row
	_subjectRow = [[UIView alloc] initWithFrame:CGRectMake(0, 44, w, 44)];
	_subjectRow.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	UILabel *subjectLabel = [self fieldLabel:@"Subject:"];
	[_subjectRow addSubview:subjectLabel];
	CGFloat sx = CGRectGetMaxX(subjectLabel.frame) + 6;
	_subjectField = [[UITextField alloc] initWithFrame:CGRectMake(sx, 12, w - sx - 46, 22)];
	_subjectField.placeholder = @"Group Subject";
	_subjectField.font = [UIFont systemFontOfSize:15];
	_subjectField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	_subjectField.delegate = self;
	[_subjectField addTarget:self action:@selector(subjectChanged) forControlEvents:UIControlEventEditingChanged];
	[_subjectRow addSubview:_subjectField];
	_countLabel = [[UILabel alloc] initWithFrame:CGRectMake(w - 42, 12, 34, 21)];
	_countLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
	_countLabel.font = [UIFont systemFontOfSize:14];
	_countLabel.textColor = WAColor(0x7F8A99);
	_countLabel.textAlignment = NSTextAlignmentRight;
	_countLabel.text = [@(kMaxSubject) description];
	[_subjectRow addSubview:_countLabel];
	[self.view addSubview:_subjectRow];

	// group icon
	_iconRow = [[UIView alloc] initWithFrame:CGRectMake(0, 88, w, 96)];
	_iconRow.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	_iconButton = [UIButton buttonWithType:UIButtonTypeCustom];
	_iconButton.frame = CGRectMake(14, 14, 64, 64);
	_iconButton.imageView.contentMode = UIViewContentModeScaleAspectFill;
	[_iconButton addTarget:self action:@selector(pickIcon) forControlEvents:UIControlEventTouchUpInside];
	[_iconRow addSubview:_iconButton];
	UILabel *iconText = [[UILabel alloc] initWithFrame:CGRectMake(90, 26, w - 100, 40)];
	iconText.text = @"Group Icon\n(optional)";
	iconText.numberOfLines = 2;
	iconText.font = [UIFont systemFontOfSize:15];
	iconText.textColor = WAColor(0x7F8A99);
	[_iconRow addSubview:iconText];
	[self.view addSubview:_iconRow];
	[self showIcon];

	for (UIView *row in @[_participantsRow, _subjectRow]) {
		UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, row.bounds.size.height - 1, w, 1)];
		line.backgroundColor = [UIColor colorWithWhite:0.8 alpha:1];
		line.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
		[row addSubview:line];
	}

	// search results overlay
	_results = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
	_results.dataSource = self;
	_results.delegate = self;
	_results.hidden = YES;
	_results.rowHeight = 48;
	[self.view addSubview:_results];

	if (self.broadcast) [self setupBroadcast];
	[self layoutTokens];
	[[WAClient shared] get:@"/api/contacts" params:@{@"about": @"0"} completion:^(id json, NSError *error) {
		self->_contacts = [json[@"contacts"] isKindOfClass:[NSArray class]] ? json[@"contacts"] : @[];
		if ([json[@"me"] length]) {
			self->_hint.text = [NSString stringWithFormat:@"IMPORTANT:\nOnly contacts with %@ in their address book will receive "
				"your broadcast messages.", json[@"me"]];
		}
	}];
}

#pragma mark Broadcast

// broadcast: message + attach panel instead
- (void)setupBroadcast {
	CGFloat w = self.view.bounds.size.width;
	_subjectRow.hidden = _iconRow.hidden = YES;
	_messageRow = [[UIView alloc] initWithFrame:CGRectMake(0, 44, w, 104)];
	_messageRow.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	_messageView = [[UITextView alloc] initWithFrame:CGRectMake(2, 2, w - 4, 100)];
	_messageView.font = [UIFont systemFontOfSize:15];
	_messageView.delegate = self;
	_messageView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[_messageRow addSubview:_messageView];
	_messagePlaceholder = [self fieldLabel:@"Message"];
	_messagePlaceholder.frame = CGRectMake(10, 10, 200, 21);
	_messagePlaceholder.textColor = WAColor(0xB3B3B3);
	[_messageRow addSubview:_messagePlaceholder];
	UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 103, w, 1)];
	line.backgroundColor = [UIColor colorWithWhite:0.8 alpha:1];
	line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[_messageRow addSubview:line];
	[self.view addSubview:_messageRow];

	_attachRow = [[UIImageView alloc] initWithFrame:CGRectMake(0, 148, w, 45)];
	((UIImageView *)_attachRow).image = WAImg(@"BrdtAttachPanel");
	if (!((UIImageView *)_attachRow).image) _attachRow.backgroundColor = WAColor(0xDADFE6);
	_attachRow.userInteractionEnabled = YES;
	_attachRow.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	NSArray *kinds = @[@[@"BrdtAttachCamera", @"Take Photo"], @[@"BrdtAttachGallery", @"Choose Existing Photo"]];
	for (NSUInteger i = 0; i < kinds.count; i++) {
		UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
		b.frame = CGRectMake(10 + i * 40, 7, 28, 23);
		UIImage *img = WAImg(kinds[i][0]);
		if (img) {
			[b setImage:img forState:UIControlStateNormal];
			[b setImage:WAImg([kinds[i][0] stringByAppendingString:@"Pressed"]) forState:UIControlStateHighlighted];
		} else {
			[b setTitle:i ? @"\U0001F5BC" : @"\U0001F4F7" forState:UIControlStateNormal];
		}
		b.accessibilityLabel = kinds[i][1];
		b.enabled = i == 1 || [UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera];
		[b addTarget:self action:@selector(attachPhoto:) forControlEvents:UIControlEventTouchUpInside];
		[_attachRow addSubview:b];
	}
	// attached photo, x removes it
	_photoButton = [UIButton buttonWithType:UIButtonTypeCustom];
	_photoButton.frame = CGRectMake(w - 52, 3, 40, 39);
	_photoButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
	_photoButton.imageView.contentMode = UIViewContentModeScaleAspectFill;
	_photoButton.clipsToBounds = YES;
	_photoButton.hidden = YES;
	[_photoButton addTarget:self action:@selector(removePhoto) forControlEvents:UIControlEventTouchUpInside];
	[_attachRow addSubview:_photoButton];
	[self.view addSubview:_attachRow];

	_hint = [[UILabel alloc] init];
	_hint.numberOfLines = 0;
	_hint.font = [UIFont systemFontOfSize:14];
	_hint.textColor = WAColor(0x7F8A99);
	_hint.textAlignment = NSTextAlignmentCenter;
	_hint.backgroundColor = [UIColor clearColor];
	_hint.text = @"IMPORTANT:\nOnly contacts with your number in their address book will receive your broadcast messages.";
	[self.view addSubview:_hint];
	[self.view bringSubviewToFront:_results];
}

- (void)textViewDidChange:(UITextView *)textView {
	_messagePlaceholder.hidden = textView.text.length > 0;
	[self updateCreate];
}

- (void)attachPhoto:(UIButton *)b {
	[self.view endEditing:YES];
	_pickingPhoto = YES;
	UIImagePickerController *picker = [[UIImagePickerController alloc] init];
	picker.sourceType = [b.accessibilityLabel isEqualToString:@"Take Photo"] ? UIImagePickerControllerSourceTypeCamera
		: UIImagePickerControllerSourceTypePhotoLibrary;
	picker.delegate = self;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)showPhoto {
	_photoButton.hidden = !_photo;
	if (!_photo) return;
	CGFloat f = MAX(40 / _photo.size.width, 39 / _photo.size.height);
	CGSize s = CGSizeMake(_photo.size.width * f, _photo.size.height * f);
	UIGraphicsBeginImageContextWithOptions(CGSizeMake(40, 39), NO, 0);
	[[UIBezierPath bezierPathWithRoundedRect:CGRectMake(1, 1, 38, 37) cornerRadius:4] addClip];
	[_photo drawInRect:CGRectMake((40 - s.width) / 2, (39 - s.height) / 2, s.width, s.height)];
	[WAImg(@"BrdtAttachedOverlay") drawInRect:CGRectMake(0, 0, 40, 39)];
	UIImage *x = WAImg(@"BrdtAttachmentRemove");
	[x drawInRect:CGRectMake(40 - 13, 1, 12, 12)];
	UIImage *thumb = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	[_photoButton setImage:thumb forState:UIControlStateNormal];
}

- (void)removePhoto {
	_photo = nil;
	[self showPhoto];
	[self updateCreate];
}

- (void)sendBroadcast {
	[self.view endEditing:YES];
	_creating = YES;
	[self updateCreate];
	UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
	[spin startAnimating];
	self.navigationItem.titleView = spin;
	NSString *text = [_messageView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSString *jids = [[_participants valueForKey:@"jid"] componentsJoinedByString:@","];
	WAJSONBlock done = ^(id json, NSError *error) {
		if (error || ![json[@"broadcast"] isKindOfClass:[NSDictionary class]]) {
			self->_creating = NO;
			self.navigationItem.titleView = nil;
			[self updateCreate];
			[[[UIAlertView alloc] initWithTitle:@"Not sent" message:error.localizedDescription delegate:nil
				cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
			return;
		}
		void (^sent)(NSDictionary *) = self.onBroadcastSent;
		[self dismissViewControllerAnimated:YES completion:^{ if (sent) sent(json[@"broadcast"]); }];
	};
	if (_photo) {
		// max 1280px jpeg
		CGFloat f = MIN(1, 1280 / MAX(_photo.size.width, _photo.size.height));
		CGSize s = CGSizeMake(roundf(_photo.size.width * f), roundf(_photo.size.height * f));
		UIGraphicsBeginImageContextWithOptions(s, YES, 1);
		[_photo drawInRect:CGRectMake(0, 0, s.width, s.height)];
		NSData *jpeg = UIImageJPEGRepresentation(UIGraphicsGetImageFromCurrentImageContext(), 0.7);
		UIGraphicsEndImageContext();
		[[WAClient shared] post:@"/api/broadcast/send" params:@{@"recipients": jids, @"caption": text} data:jpeg
			contentType:@"image/jpeg" completion:done];
	} else {
		[[WAClient shared] post:@"/api/broadcast/send" params:@{@"recipients": jids, @"text": text} completion:done];
	}
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	if (!_participants.count) [_searchField becomeFirstResponder];
}

- (UILabel *)fieldLabel:(NSString *)text {
	UILabel *l = [[UILabel alloc] init];
	l.text = text;
	l.font = [UIFont systemFontOfSize:15];
	l.textColor = WAColor(0x7F7F7F);
	[l sizeToFit];
	l.frame = CGRectMake(8, 12, l.bounds.size.width, 21);
	return l;
}

// mail style tokens
- (UIButton *)tokenFor:(NSDictionary *)c {
	UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
	[b setTitle:c[@"name"] forState:UIControlStateNormal];
	b.titleLabel.font = [UIFont systemFontOfSize:15];
	[b setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
	b.backgroundColor = [UIColor colorWithRed:0.86f green:0.90f blue:0.98f alpha:1];
	b.layer.borderColor = [UIColor colorWithRed:0.58f green:0.68f blue:0.90f alpha:1].CGColor;
	b.layer.borderWidth = 1;
	b.layer.cornerRadius = 11;
	b.contentEdgeInsets = UIEdgeInsetsMake(0, 9, 0, 9);
	[b sizeToFit];
	CGRect f = b.frame;
	f.size.height = 23;
	f.size.width = MIN(f.size.width, 200);
	b.frame = f;
	[b addTarget:self action:@selector(tokenTapped:) forControlEvents:UIControlEventTouchUpInside];
	return b;
}

- (void)layoutTokens {
	for (UIView *v in _tokens.subviews) [v removeFromSuperview];
	CGFloat w = self.view.bounds.size.width;
	CGFloat left = 104, right = w - 44, x = left, y = 10;
	for (NSUInteger i = 0; i < _participants.count; i++) {
		UIButton *t = [self tokenFor:_participants[i]];
		t.tag = (NSInteger)i;
		if (x + t.bounds.size.width > right && x > left) {
			x = 8;
			y += 30;
		}
		t.frame = CGRectMake(x, y, t.bounds.size.width, 23);
		[_tokens addSubview:t];
		x += t.bounds.size.width + 5;
	}
	if (right - x < 60) {
		x = 8;
		y += 30;
	}
	_tokens.frame = CGRectMake(0, 0, w, y + 34);
	_searchField.frame = CGRectMake(x, y + 1, right - x, 22);
	CGFloat h = y + 34;
	_participantsRow.frame = CGRectMake(0, 0, w, h);
	_subjectRow.frame = CGRectMake(0, h, w, 44);
	_iconRow.frame = CGRectMake(0, h + 44, w, 96);
	if (self.broadcast) {
		_messageRow.frame = CGRectMake(0, h, w, 104);
		_attachRow.frame = CGRectMake(0, h + 104, w, 45);
		_hint.frame = CGRectMake(20, h + 104 + 45 + 12, w - 40, 54);
	}
	_results.frame = CGRectMake(0, h, w, self.view.bounds.size.height - h);
	[self updateCreate];
}

- (void)tokenTapped:(UIButton *)t {
	[_participants removeObjectAtIndex:(NSUInteger)t.tag];
	[self layoutTokens];
}

- (void)searchChanged {
	NSString *q = _searchField.text.lowercaseString;
	NSMutableArray *m = [NSMutableArray array];
	if (q.length) {
		for (NSDictionary *c in _contacts) {
			if ([_participants containsObject:c]) continue;
			if ([[c[@"name"] lowercaseString] rangeOfString:q].location != NSNotFound ||
				[[c[@"phone"] stringByReplacingOccurrencesOfString:@" " withString:@""] rangeOfString:q].location != NSNotFound) [m addObject:c];
		}
	}
	_matches = m;
	_results.hidden = !q.length;
	[_results reloadData];
}

- (BOOL)textFieldShouldReturn:(UITextField *)f {
	if (f == _searchField && _matches.count == 1) [self addParticipant:_matches[0]];
	else if (f == _searchField) [self.broadcast ? (UIResponder *)_messageView : _subjectField becomeFirstResponder];
	else [f resignFirstResponder];
	return YES;
}

- (BOOL)textField:(UITextField *)f shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)s {
	if (f == _subjectField) return f.text.length - range.length + s.length <= (NSUInteger)kMaxSubject;
	// backspace removes last token
	if (f == _searchField && !f.text.length && !s.length && _participants.count) {
		[_participants removeLastObject];
		[self layoutTokens];
	}
	return YES;
}

- (void)subjectChanged {
	_countLabel.text = [@(kMaxSubject - (NSInteger)_subjectField.text.length) description];
	[self updateCreate];
}

- (void)updateCreate {
	if (self.broadcast) {
		NSString *m = [_messageView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		self.navigationItem.rightBarButtonItem.enabled = !_creating && _participants.count > 0 && (m.length > 0 || _photo);
		return;
	}
	NSString *s = [_subjectField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
	self.navigationItem.rightBarButtonItem.enabled = !_creating && s.length > 0 && _participants.count > 0;
}

- (BOOL)tooManyRecipients:(NSUInteger)count {
	if (!self.broadcast || count <= kMaxRecipients) return NO;
	[[[UIAlertView alloc] initWithTitle:nil message:[NSString stringWithFormat:@"Broadcast to at most %lu people at a time.",
		(unsigned long)kMaxRecipients] delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
	return YES;
}

- (void)addParticipant:(NSDictionary *)c {
	if ([self tooManyRecipients:_participants.count + 1]) return;
	if (![_participants containsObject:c]) [_participants addObject:c];
	_searchField.text = @"";
	[self searchChanged];
	[self layoutTokens];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return _matches.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
	NSDictionary *c = _matches[indexPath.row];
	cell.textLabel.text = c[@"name"];
	cell.detailTextLabel.text = c[@"phone"];
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[self addParticipant:_matches[indexPath.row]];
}

- (void)pickContacts {
	WAPeoplePickerController *picker = [[WAPeoplePickerController alloc] init];
	picker.contacts = _contacts ?: @[];
	picker.selected = [NSMutableSet setWithArray:[_participants valueForKey:@"jid"]];
	picker.onDone = ^(NSSet *jids) {
		NSMutableArray *list = [NSMutableArray array];
		for (NSDictionary *c in self->_participants) if ([jids containsObject:c[@"jid"]]) [list addObject:c];
		for (NSDictionary *c in self->_contacts) if ([jids containsObject:c[@"jid"]] && ![list containsObject:c]) [list addObject:c];
		if ([self tooManyRecipients:list.count]) [list removeObjectsInRange:NSMakeRange(kMaxRecipients, list.count - kMaxRecipients)];
		self->_participants = list;
		[self layoutTokens];
	};
	[self presentViewController:[[UINavigationController alloc] initWithRootViewController:picker] animated:YES completion:nil];
}

#pragma mark Icon

- (void)showIcon {
	UIImage *frame = WAImg(@"GroupIconFrameEdit");
	UIImage *img = _icon ?: WAImg(@"GroupChat");
	UIGraphicsBeginImageContextWithOptions(CGSizeMake(64, 64), NO, 0);
	[[UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 2, 60, 60) cornerRadius:5] addClip];
	[img drawInRect:CGRectMake(2, 2, 60, 60)];
	UIImage *composed = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	if (frame) {
		UIGraphicsBeginImageContextWithOptions(CGSizeMake(64, 64), NO, 0);
		[composed drawInRect:CGRectMake(0, 0, 64, 64)];
		[frame drawInRect:CGRectMake(0, 0, 64, 64)];
		composed = UIGraphicsGetImageFromCurrentImageContext();
		UIGraphicsEndImageContext();
	}
	[_iconButton setImage:composed forState:UIControlStateNormal];
}

- (void)pickIcon {
	[self.view endEditing:YES];
	UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:@"Group Icon" delegate:self cancelButtonTitle:nil
		destructiveButtonTitle:nil otherButtonTitles:nil];
	if ([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) [sheet addButtonWithTitle:@"Take Photo"];
	[sheet addButtonWithTitle:@"Choose Existing Photo"];
	if (_icon) sheet.destructiveButtonIndex = [sheet addButtonWithTitle:@"Delete Photo"];
	sheet.cancelButtonIndex = [sheet addButtonWithTitle:@"Cancel"];
	[sheet showInView:self.view];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
	if (index == sheet.cancelButtonIndex) return;
	if (index == sheet.destructiveButtonIndex) {
		_icon = nil;
		[self showIcon];
		return;
	}
	UIImagePickerController *picker = [[UIImagePickerController alloc] init];
	picker.sourceType = [[sheet buttonTitleAtIndex:index] isEqualToString:@"Take Photo"] ? UIImagePickerControllerSourceTypeCamera
		: UIImagePickerControllerSourceTypePhotoLibrary;
	picker.allowsEditing = YES;
	picker.delegate = self;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
	if (_pickingPhoto) {
		_pickingPhoto = NO;
		_photo = info[UIImagePickerControllerOriginalImage];
		[self showPhoto];
		[self updateCreate];
		[picker dismissViewControllerAnimated:YES completion:nil];
		return;
	}
	_icon = info[UIImagePickerControllerEditedImage] ?: info[UIImagePickerControllerOriginalImage];
	[self showIcon];
	[picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
	_pickingPhoto = NO;
	[picker dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark Create

- (void)cancel {
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (void)create {
	[self.view endEditing:YES];
	_creating = YES;
	[self updateCreate];
	UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
	[spin startAnimating];
	self.navigationItem.titleView = spin;
	NSString *subject = [_subjectField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
	NSString *jids = [[_participants valueForKey:@"jid"] componentsJoinedByString:@","];
	[[WAClient shared] post:@"/api/group/create" params:@{@"subject": subject, @"participants": jids} completion:^(id json, NSError *error) {
		if (error || ![json[@"jid"] length]) {
			self->_creating = NO;
			self.navigationItem.titleView = nil;
			[self updateCreate];
			[[[UIAlertView alloc] initWithTitle:nil message:@"Group was not created. Tap “Try Again” to create this group."
				delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
			return;
		}
		NSString *jid = json[@"jid"];
		void (^finish)(void) = ^{
			NSArray *failed = [json[@"failed"] isKindOfClass:[NSArray class]] ? json[@"failed"] : @[];
			[self dismissViewControllerAnimated:YES completion:^{
				[[NSNotificationCenter defaultCenter] postNotificationName:@"WAOpenChatNotification" object:nil
					userInfo:@{@"jid": jid, @"name": subject, @"group": @YES}];
				if (failed.count) {
					NSString *msg = [NSString stringWithFormat:@"Failed to add %@ to the group “%@”.",
						[failed componentsJoinedByString:@", "], subject];
					[[[UIAlertView alloc] initWithTitle:nil message:msg delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
				}
			}];
		};
		if (!self->_icon) {
			finish();
			return;
		}
		[[WAClient shared] post:@"/api/group/photo" params:@{@"jid": jid}
			data:UIImageJPEGRepresentation(self->_icon, 0.85) contentType:@"image/jpeg" completion:^(id j, NSError *e) {
				finish();
			}];
	}];
}

@end
