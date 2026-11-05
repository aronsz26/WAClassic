#import "WAFavoritesViewController.h"
#import "WAInfoViewController.h"
#import "WANewGroupViewController.h"
#import "WAClient.h"
#import "WAAssets.h"
#import "WAUtil.h"

// jids in order
static NSString *const kFavoritesKey = @"favorites", *const kGeneratedKey = @"favoritesGenerated";

@implementation WAFavoritesViewController {
	NSArray *_contacts;
	NSMutableArray *_favorites;
	NSArray *_shown; // search results
	UISearchBar *_search;
	UIView *_empty;
}

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStylePlain])) {
		self.title = @"Favorites";
		self.tabBarItem = [[UITabBarItem alloc] initWithTabBarSystemItem:UITabBarSystemItemFavorites tag:0];
		[WAFavoritesViewController forgetGenerated];
		_favorites = [[[NSUserDefaults standardUserDefaults] arrayForKey:kFavoritesKey] mutableCopy] ?: [NSMutableArray array];
	}
	return self;
}

// first version auto-filled everything, clear that once
+ (void)forgetGenerated {
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	if (![d boolForKey:kGeneratedKey]) return;
	[d removeObjectForKey:kGeneratedKey];
	[d removeObjectForKey:kFavoritesKey];
	[d synchronize];
}

+ (BOOL)isFavorite:(NSString *)jid {
	[self forgetGenerated];
	return jid && [[[NSUserDefaults standardUserDefaults] arrayForKey:kFavoritesKey] containsObject:jid];
}

+ (void)setFavorite:(NSString *)jid on:(BOOL)on {
	if (!jid) return;
	[self forgetGenerated];
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	NSMutableArray *list = [[d arrayForKey:kFavoritesKey] mutableCopy] ?: [NSMutableArray array];
	[list removeObject:jid];
	if (on) [list addObject:jid];
	[d setObject:list forKey:kFavoritesKey];
	[d synchronize];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.tableView.rowHeight = 50;
	self.tableView.allowsSelectionDuringEditing = NO;
	_search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
	_search.placeholder = @"Search";
	_search.delegate = self;
	_search.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	self.tableView.tableHeaderView = _search;
	self.navigationItem.leftBarButtonItem = self.editButtonItem;
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
		target:self action:@selector(add)];
	[self updateFooter];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	// might have changed meanwhile
	_favorites = [[[NSUserDefaults standardUserDefaults] arrayForKey:kFavoritesKey] mutableCopy] ?: [NSMutableArray array];
	[self filter];
	[self load];
}

- (void)load {
	if (![WAClient shared].configured) return;
	[[WAClient shared] get:@"/api/contacts" params:nil completion:^(id json, NSError *error) {
		if (![json[@"contacts"] isKindOfClass:[NSArray class]]) return;
		self->_contacts = json[@"contacts"];
		[self filter];
	}];
}

- (void)save {
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	[d setObject:_favorites forKey:kFavoritesKey];
	[d synchronize];
}

// keep the number if they're not a contact anymore
- (NSDictionary *)contactFor:(NSString *)jid {
	for (NSDictionary *c in _contacts) {
		if ([c[@"jid"] isEqualToString:jid]) return c;
	}
	NSString *number = [[jid componentsSeparatedByString:@"@"] firstObject];
	return @{@"jid": jid, @"name": [@"+" stringByAppendingString:number], @"phone": @""};
}

- (void)filter {
	NSString *q = _search.text.lowercaseString;
	NSMutableArray *shown = [NSMutableArray array];
	for (NSString *jid in _favorites) {
		NSDictionary *c = [self contactFor:jid];
		if (q.length && [[c[@"name"] lowercaseString] rangeOfString:q].location == NSNotFound &&
			[c[@"phone"] rangeOfString:q].location == NSNotFound) continue;
		[shown addObject:c];
	}
	_shown = shown;
	[self.tableView reloadData];
	[self updateFooter];
}

#pragma mark - Footer: count, empty star, Delete All

- (void)updateFooter {
	CGFloat w = self.view.bounds.size.width;
	if (self.editing && _favorites.count) {
		// delete all button
		UIView *f = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 70)];
		UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
		b.frame = CGRectMake(10, 14, w - 20, 44);
		UIImage *red = WAStretch(@"RedButton", 0, 10, 0, 10);
		[b setBackgroundImage:red forState:UIControlStateNormal];
		[b setBackgroundImage:WAStretch(@"RedButtonPressed", 0, 10, 0, 10) forState:UIControlStateHighlighted];
		if (!red) b.backgroundColor = WAColor(0xC9302C);
		b.titleLabel.font = [UIFont boldSystemFontOfSize:18];
		b.titleLabel.shadowOffset = CGSizeMake(0, -1);
		[b setTitleShadowColor:[UIColor colorWithWhite:0 alpha:0.4] forState:UIControlStateNormal];
		[b setTitle:@"Delete All Favorites" forState:UIControlStateNormal];
		[b addTarget:self action:@selector(deleteAllTapped) forControlEvents:UIControlEventTouchUpInside];
		[f addSubview:b];
		self.tableView.tableFooterView = f;
		return;
	}
	if (!_favorites.count && _contacts) {
		// empty state
		if (!_empty) {
			_empty = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 290)];
			UIImageView *star = [[UIImageView alloc] initWithFrame:CGRectMake(floorf((w - 220) / 2), 0, 220, 200)];
			star.image = WAImg(@"NoFaves");
			star.contentMode = UIViewContentModeCenter;
			[_empty addSubview:star];
			CGFloat y = star.image ? 190 : 40;
			UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w - 40, 24)];
			title.text = @"No Favorites Yet";
			title.font = [UIFont boldSystemFontOfSize:19];
			UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(30, y + 28, w - 60, 40)];
			hint.text = @"Tap + to add a contact to your Favorites.";
			hint.font = [UIFont systemFontOfSize:15];
			hint.numberOfLines = 2;
			for (UILabel *l in @[title, hint]) {
				l.textColor = WAColor(0x7F8A99);
				l.textAlignment = NSTextAlignmentCenter;
				l.backgroundColor = [UIColor clearColor];
				l.shadowColor = [UIColor whiteColor];
				l.shadowOffset = CGSizeMake(0, 1);
				[_empty addSubview:l];
			}
		}
		self.tableView.tableFooterView = _empty;
		return;
	}
	// "12 Favorites"
	UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, w, 50)];
	NSUInteger n = _favorites.count;
	l.text = _contacts ? [NSString stringWithFormat:n == 1 ? @"%lu Favorite" : @"%lu Favorites", (unsigned long)n] : nil;
	l.font = [UIFont systemFontOfSize:17];
	l.textColor = WAColor(0x7F8A99);
	l.textAlignment = NSTextAlignmentCenter;
	l.backgroundColor = [UIColor clearColor];
	self.tableView.tableFooterView = l;
}

- (void)deleteAllTapped {
	UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:@"Cancel"
		destructiveButtonTitle:@"Delete All Favorites" otherButtonTitles:nil];
	[sheet showInView:self.tabBarController.view ?: self.view];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
	if (index != sheet.destructiveButtonIndex) return;
	[_favorites removeAllObjects];
	[self save];
	[self setEditing:NO animated:YES];
	[self filter];
}

#pragma mark - Edit, add

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
	if (editing && _search.text.length) { // no moving while searching
		_search.text = @"";
		[self filter];
	}
	[_search resignFirstResponder];
	[super setEditing:editing animated:animated];
	self.navigationItem.rightBarButtonItem.enabled = !editing;
	[self updateFooter];
}

- (void)add {
	[_search resignFirstResponder];
	WAPeoplePickerController *picker = [[WAPeoplePickerController alloc] init];
	NSArray *sorted = [(_contacts ?: @[]) sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
		return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
	}];
	picker.contacts = sorted;
	picker.selected = [NSMutableSet setWithArray:_favorites];
	picker.onDone = ^(NSSet *jids) {
		// keep order, new ones at the end
		NSMutableArray *list = [NSMutableArray array];
		for (NSString *jid in self->_favorites) if ([jids containsObject:jid]) [list addObject:jid];
		for (NSDictionary *c in sorted) if ([jids containsObject:c[@"jid"]] && ![list containsObject:c[@"jid"]]) [list addObject:c[@"jid"]];
		self->_favorites = list;
		[self save];
		[self filter];
	};
	[self presentViewController:[[UINavigationController alloc] initWithRootViewController:picker] animated:YES completion:nil];
}

#pragma mark - Search

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
	[self filter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
	[searchBar resignFirstResponder];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
	[_search resignFirstResponder];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return _shown.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"fav"];
	if (!cell) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"fav"];
		cell.textLabel.font = [UIFont boldSystemFontOfSize:17];
		cell.detailTextLabel.font = [UIFont systemFontOfSize:14];
		cell.detailTextLabel.textColor = WAColor(0x7F8A99);
		cell.accessoryType = UITableViewCellAccessoryDetailDisclosureButton;
	}
	NSDictionary *c = _shown[indexPath.row];
	cell.textLabel.text = c[@"name"];
	NSString *about = c[@"about"];
	cell.detailTextLabel.text = about.length ? about : nil; // center the name if no status
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	[_search resignFirstResponder];
	NSDictionary *c = _shown[indexPath.row];
	[[NSNotificationCenter defaultCenter] postNotificationName:@"WAOpenChatNotification" object:nil
		userInfo:@{@"jid": c[@"jid"], @"name": c[@"name"] ?: @""}];
}

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {
	NSDictionary *c = _shown[indexPath.row];
	[self.navigationController pushViewController:[[WAInfoViewController alloc] initWithJID:c[@"jid"] name:c[@"name"] group:NO]
		animated:YES];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
	if (style != UITableViewCellEditingStyleDelete) return;
	[_favorites removeObject:_shown[indexPath.row][@"jid"]];
	[self save];
	NSMutableArray *shown = [_shown mutableCopy];
	[shown removeObjectAtIndex:indexPath.row];
	_shown = shown;
	[tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
	[self updateFooter];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
	return _search.text.length == 0;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
	NSString *jid = _favorites[from.row];
	[_favorites removeObjectAtIndex:from.row];
	[_favorites insertObject:jid atIndex:to.row];
	[self save];
	NSMutableArray *shown = [_shown mutableCopy];
	id c = shown[from.row];
	[shown removeObjectAtIndex:from.row];
	[shown insertObject:c atIndex:to.row];
	_shown = shown;
}

@end
