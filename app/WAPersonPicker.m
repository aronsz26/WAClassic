#import "WAPersonPicker.h"
#import "WAClient.h"
#import "WAUtil.h"

@implementation WAPersonPicker {
	NSArray *_all; // nil = loading
	NSArray *_titles;
	NSArray *_sections;
	UISearchBar *_search;
}

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStylePlain])) self.title = @"New Message";
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.tableView.rowHeight = 50;
	_search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
	_search.placeholder = @"Search";
	_search.delegate = self;
	_search.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	self.tableView.tableHeaderView = _search;
	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
		target:self action:@selector(cancel)];
	[[WAClient shared] get:@"/api/contacts" params:nil completion:^(id json, NSError *error) {
		self->_all = [json[@"contacts"] isKindOfClass:[NSArray class]] ? json[@"contacts"] : @[];
		[self filter];
	}];
}

- (void)cancel {
	[self dismissViewControllerAnimated:YES completion:nil];
}

// A-Z, # last, search names + numbers
- (void)filter {
	NSString *q = _search.text.lowercaseString;
	NSMutableDictionary *byLetter = [NSMutableDictionary dictionary];
	for (NSDictionary *c in _all) {
		NSString *name = c[@"name"];
		if (q.length && [[name lowercaseString] rangeOfString:q].location == NSNotFound &&
			[c[@"phone"] rangeOfString:q].location == NSNotFound) continue;
		NSString *letter = name.length ? [[[name substringToIndex:1] decomposedStringWithCanonicalMapping] substringToIndex:1].uppercaseString : @"#";
		if (![[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:[letter characterAtIndex:0]]) letter = @"#";
		if (!byLetter[letter]) byLetter[letter] = [NSMutableArray array];
		[byLetter[letter] addObject:c];
	}
	NSArray *letters = [[byLetter allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
		if ([a isEqualToString:@"#"]) return NSOrderedDescending;
		if ([b isEqualToString:@"#"]) return NSOrderedAscending;
		return [a compare:b];
	}];
	NSMutableArray *sections = [NSMutableArray array];
	for (NSString *l in letters) {
		[sections addObject:[byLetter[l] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
			return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
		}]];
	}
	_titles = letters;
	_sections = sections;
	[self.tableView reloadData];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
	[self filter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
	[searchBar resignFirstResponder];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
	[_search resignFirstResponder];
}

// loading / no contacts row
- (BOOL)placeholder {
	return !_all || !_sections.count;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return [self placeholder] ? 1 : _sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return [self placeholder] ? 1 : [_sections[section] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	return [self placeholder] ? nil : _titles[section];
}

- (NSArray *)sectionIndexTitlesForTableView:(UITableView *)tableView {
	return [self placeholder] || _search.text.length ? nil : _titles;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	if ([self placeholder]) {
		UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
		cell.textLabel.textAlignment = NSTextAlignmentCenter;
		if (!_all) {
			cell.textLabel.text = @"loading...";
			cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
			cell.textLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1];
		} else {
			cell.textLabel.text = @"No Contacts";
			cell.textLabel.font = [UIFont boldSystemFontOfSize:18];
			cell.textLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1];
		}
		return cell;
	}
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"person"];
	if (!cell) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"person"];
		cell.textLabel.font = [UIFont boldSystemFontOfSize:17];
		cell.detailTextLabel.font = [UIFont systemFontOfSize:14];
		cell.detailTextLabel.textColor = WAColor(0x7F8A99);
	}
	NSDictionary *c = _sections[indexPath.section][indexPath.row];
	cell.textLabel.text = c[@"name"];
	NSString *about = c[@"about"];
	cell.detailTextLabel.text = about.length ? about : nil;
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if ([self placeholder]) return;
	NSDictionary *c = _sections[indexPath.section][indexPath.row];
	void (^pick)(NSDictionary *) = self.onPick;
	[self dismissViewControllerAnimated:YES completion:^{ if (pick) pick(c); }];
}

@end
