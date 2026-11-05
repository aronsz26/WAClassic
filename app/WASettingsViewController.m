#import "WASettingsViewController.h"
#import "WAClient.h"
#import "WAAssets.h"

@implementation WASettingsViewController {
	UITextField *_homeField, *_awayField, *_tokenField, *_pinField;
	NSString *_statusText;
}

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
		self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Settings" image:WAImg(@"Settings") tag:4];
	}
	return self;
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[self apply];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Network Status";
	WAClient *c = [WAClient shared];
	_homeField = [self fieldWithText:c.homeURL placeholder:@"http://192.168.1.20:8097"];
	_awayField = [self fieldWithText:c.awayURL placeholder:@"https://…:25567"];
	_homeField.keyboardType = _awayField.keyboardType = UIKeyboardTypeURL;
	_tokenField = [self fieldWithText:c.token placeholder:@"Key"];
	_tokenField.secureTextEntry = YES;
	_pinField = [self fieldWithText:c.pin placeholder:@"SHA-256 of the certificate"];
	[self check];
}

- (UITextField *)fieldWithText:(NSString *)text placeholder:(NSString *)placeholder {
	UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 190, 24)];
	f.text = text;
	f.placeholder = placeholder;
	f.autocorrectionType = UITextAutocorrectionTypeNo;
	f.autocapitalizationType = UITextAutocapitalizationTypeNone;
	f.clearButtonMode = UITextFieldViewModeWhileEditing;
	f.delegate = self;
	f.font = [UIFont systemFontOfSize:15];
	return f;
}

- (void)apply {
	WAClient *c = [WAClient shared];
	NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
	c.homeURL = [_homeField.text stringByTrimmingCharactersInSet:ws];
	c.awayURL = [_awayField.text stringByTrimmingCharactersInSet:ws];
	c.token = [_tokenField.text stringByTrimmingCharactersInSet:ws];
	c.pin = [_pinField.text stringByTrimmingCharactersInSet:ws];
	[c saveSettings];
}

- (void)check {
	WAClient *c = [WAClient shared];
	if (!c.configured) {
		_statusText = @"Enter address and key";
		[self.tableView reloadData];
		return;
	}
	_statusText = @"Checking…";
	[self.tableView reloadData];
	[c chooseServer:^(BOOL reachable) {
		if (!reachable) {
			self->_statusText = @"Bridge not reachable";
			[self.tableView reloadData];
			return;
		}
		[self status];
	}];
}

- (void)status {
	WAClient *c = [WAClient shared];
	NSString *where = c.away ? @"away" : @"home";
	[c get:@"/api/status" params:nil completion:^(id json, NSError *error) {
		if (error) {
			self->_statusText = error.localizedDescription;
		} else if (![json[@"paired"] boolValue]) {
			self->_statusText = @"Bridge running, but not linked";
		} else {
			c.ownJID = json[@"jid"];
			self->_statusText = [json[@"connected"] boolValue]
				? [NSString stringWithFormat:@"Connected as %@ (%@)", json[@"pushName"] ?: @"?", where]
				: @"Bridge reached, WhatsApp disconnected";
		}
		[self.tableView reloadData];
	}];
}

- (void)done {
	[self apply];
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
	[textField resignFirstResponder];
	[self apply];
	[self check];
	return YES;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return section == 0 ? 4 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	return section == 0 ? @"WA Classic Bridge" : @"Status";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	return section == 1 ? @"WA Classic is an unofficial client, not affiliated with WhatsApp or Meta. It runs as a linked device through your own bridge." : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
	if (indexPath.section == 0) {
		NSArray *titles = @[@"Home", @"Away", @"Key", @"Certificate"];
		NSArray *fields = @[_homeField, _awayField, _tokenField, _pinField];
		cell.textLabel.text = titles[indexPath.row];
		cell.accessoryView = fields[indexPath.row];
	} else {
		cell.textLabel.text = _statusText;
		cell.textLabel.font = [UIFont systemFontOfSize:15];
		cell.textLabel.adjustsFontSizeToFitWidth = YES;
		cell.selectionStyle = UITableViewCellSelectionStyleBlue;
	}
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (indexPath.section == 1) {
		[self apply];
		[self check];
	}
}

@end
