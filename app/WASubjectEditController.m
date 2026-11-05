#import "WASubjectEditController.h"
#import "WAClient.h"
#import "WAUtil.h"

static const NSInteger kMaxSubject = 25;

@implementation WASubjectEditController {
	NSString *_jid, *_subject;
	UITextField *_field;
	UILabel *_count;
}

- (instancetype)initWithGroup:(NSString *)jid subject:(NSString *)subject {
	if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
		_jid = [jid copy];
		_subject = [subject copy] ?: @"";
		self.title = @"Subject";
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
		target:self action:@selector(cancel)];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
		target:self action:@selector(save)];
	self.navigationItem.rightBarButtonItem.enabled = NO;
	_field = [[UITextField alloc] initWithFrame:CGRectMake(10, 11, 280, 22)];
	_field.font = [UIFont systemFontOfSize:17];
	_field.placeholder = @"Group Subject";
	_field.text = _subject;
	_field.clearButtonMode = UITextFieldViewModeWhileEditing;
	_field.returnKeyType = UIReturnKeyDone;
	_field.delegate = self;
	[_field addTarget:self action:@selector(changed) forControlEvents:UIControlEventEditingChanged];
	// chars left
	UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 40)];
	_count = [[UILabel alloc] initWithFrame:CGRectMake(header.bounds.size.width - 62, 14, 42, 21)];
	_count.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
	_count.font = [UIFont systemFontOfSize:15];
	_count.textColor = WAColor(0x808080);
	_count.textAlignment = NSTextAlignmentRight;
	_count.backgroundColor = [UIColor clearColor];
	[header addSubview:_count];
	self.tableView.tableHeaderView = header;
	[self changed];
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	[_field becomeFirstResponder];
}

- (NSString *)trimmed {
	return [_field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

- (void)changed {
	_count.text = [@(kMaxSubject - (NSInteger)_field.text.length) description];
	NSString *t = [self trimmed];
	self.navigationItem.rightBarButtonItem.enabled = t.length > 0 && ![t isEqualToString:_subject];
}

- (BOOL)textField:(UITextField *)f shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)s {
	return f.text.length - range.length + s.length <= (NSUInteger)kMaxSubject;
}

- (BOOL)textFieldShouldReturn:(UITextField *)f {
	if (self.navigationItem.rightBarButtonItem.enabled) [self save];
	return NO;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
	_field.frame = CGRectMake(10, 11, cell.contentView.bounds.size.width - 20, 22);
	_field.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[cell.contentView addSubview:_field];
	return cell;
}

- (void)cancel {
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (void)save {
	NSString *subject = [self trimmed];
	self.navigationItem.rightBarButtonItem.enabled = NO;
	[[WAClient shared] post:@"/api/group/subject" params:@{@"jid": _jid, @"subject": subject} completion:^(id json, NSError *error) {
		if (error) {
			self.navigationItem.rightBarButtonItem.enabled = YES;
			[[[UIAlertView alloc] initWithTitle:nil message:error.localizedDescription delegate:nil cancelButtonTitle:@"OK"
				otherButtonTitles:nil] show];
			return;
		}
		void (^saved)(NSString *) = self.onSaved;
		[self dismissViewControllerAnimated:YES completion:^{ if (saved) saved(subject); }];
	}];
}

@end
