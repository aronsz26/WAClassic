#import "WAContactsViewController.h"
#import "WAInfoViewController.h"
#import "WAClient.h"
#import "WAAssets.h"
#import "WAUtil.h"

@implementation WAContactsViewController {
	NSArray *_all;
	NSArray *_titles;
	NSArray *_sections;
	NSString *_myNumber;
	UISearchBar *_search;
	UILabel *_myNumberLabel;
}

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStylePlain])) {
		self.title = @"All Contacts";
		self.tabBarItem = [[UITabBarItem alloc] initWithTabBarSystemItem:UITabBarSystemItemContacts tag:2];
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.tableView.rowHeight = 50;
	UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44 + 30)];
	_search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, header.bounds.size.width, 44)];
	_search.placeholder = @"Search";
	_search.delegate = self;
	_search.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[header addSubview:_search];
	_myNumberLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 44, header.bounds.size.width - 20, 30)];
	_myNumberLabel.font = [UIFont boldSystemFontOfSize:14];
	_myNumberLabel.textColor = WAColor(0x7F8A99);
	_myNumberLabel.textAlignment = NSTextAlignmentCenter;
	_myNumberLabel.backgroundColor = [UIColor clearColor];
	[header addSubview:_myNumberLabel];
	self.tableView.tableHeaderView = header;
	[self load];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	if (!_all) [self load];
}

- (void)load {
	if (![WAClient shared].configured) return;
	[[WAClient shared] get:@"/api/contacts" params:nil completion:^(id json, NSError *error) {
		if (![json[@"contacts"] isKindOfClass:[NSArray class]]) return;
		self->_all = json[@"contacts"];
		self->_myNumber = json[@"me"];
		self->_myNumberLabel.text = self->_myNumber.length ? [NSString stringWithFormat:@"My Number: %@", self->_myNumber] : nil;
		[self filter];
	}];
}

- (void)filter {
	NSString *q = [_search.text lowercaseString];
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
	for (NSString *l in letters) [sections addObject:byLetter[l]];
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return _sections.count + 1; // last section = count
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return section < (NSInteger)_sections.count ? [_sections[section] count] : 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	return section < (NSInteger)_titles.count ? _titles[section] : nil;
}

- (NSArray *)sectionIndexTitlesForTableView:(UITableView *)tableView {
	return _search.text.length ? nil : _titles;
}

- (NSInteger)tableView:(UITableView *)tableView sectionForSectionIndexTitle:(NSString *)title atIndex:(NSInteger)index {
	return index;
}

// "98 Contacts"
- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
	if (section != (NSInteger)_sections.count || !_all) return nil;
	NSUInteger n = 0;
	for (NSArray *s in _sections) n += s.count;
	UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 50)];
	l.text = n ? [NSString stringWithFormat:@"%lu %@", (unsigned long)n, n == 1 ? @"Contact" : @"Contacts"] : @"No Contacts";
	l.font = [UIFont systemFontOfSize:17];
	l.textColor = WAColor(0x7F8A99);
	l.textAlignment = NSTextAlignmentCenter;
	l.backgroundColor = [UIColor clearColor];
	return l;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
	return section == (NSInteger)_sections.count ? 50 : 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"contact"];
	if (!cell) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"contact"];
		cell.textLabel.font = [UIFont boldSystemFontOfSize:17];
		cell.detailTextLabel.font = [UIFont systemFontOfSize:14];
		cell.detailTextLabel.textColor = WAColor(0x7F8A99);
	}
	NSDictionary *c = _sections[indexPath.section][indexPath.row];
	cell.textLabel.text = c[@"name"];
	NSString *about = c[@"about"];
	cell.detailTextLabel.text = about.length ? about : @" ";
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	[_search resignFirstResponder];
	NSDictionary *c = _sections[indexPath.section][indexPath.row];
	[self.navigationController pushViewController:[[WAInfoViewController alloc] initWithJID:c[@"jid"] name:c[@"name"] group:NO]
		animated:YES];
}

@end
