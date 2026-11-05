#import "WAStatusViewController.h"
#import "WAAssets.h"
#import "WAUtil.h"

// status doesn't work yet, so the tab just says so.
// bubble drawn here like the NoFaves star, no asset needed

static CGPathRef BubblePath(void) {
	CGFloat x = 27, y = 18, w = 136, h = 88, r = 26;
	CGMutablePathRef p = CGPathCreateMutable();
	CGPathMoveToPoint(p, NULL, x + r, y);
	CGPathAddArcToPoint(p, NULL, x + w, y, x + w, y + h, r);
	CGPathAddArcToPoint(p, NULL, x + w, y + h, x, y + h, r);
	CGPathAddLineToPoint(p, NULL, x + 48, y + h);
	CGPathAddLineToPoint(p, NULL, x + 12, y + h + 24);
	CGPathAddLineToPoint(p, NULL, x + r, y + h);
	CGPathAddArcToPoint(p, NULL, x, y + h, x, y, r);
	CGPathAddArcToPoint(p, NULL, x, y, x + r, y, r);
	CGPathCloseSubpath(p);
	return p;
}

static void AddBubble(CGContextRef c, CGPathRef bubble) {
	CGContextBeginPath(c);
	CGContextAddPath(c, bubble);
	CGContextSetLineWidth(c, 10);
	CGContextSetLineJoin(c, kCGLineJoinRound);
	CGContextReplacePathWithStrokedPath(c);
	for (int i = -1; i <= 1; i++) CGContextAddEllipseInRect(c, CGRectMake(95 + i * 32 - 8, 54, 16, 16));
}

static UIImage *SoonImage(void) {
	CGSize size = CGSizeMake(190, 145);
	UIGraphicsBeginImageContextWithOptions(size, NO, 0);
	CGContextRef c = UIGraphicsGetCurrentContext();
	CGPathRef bubble = BubblePath();

	CGContextSaveGState(c);
	CGContextTranslateCTM(c, 0, 1);
	AddBubble(c, bubble);
	CGContextSetRGBFillColor(c, 1, 1, 1, 0.7f);
	CGContextFillPath(c);
	CGContextRestoreGState(c);

	AddBubble(c, bubble);
	CGContextSetFillColorWithColor(c, WAColor(0x7F8A99).CGColor);
	CGContextFillPath(c);

	CGPathRelease(bubble);
	UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return image;
}

@implementation WAStatusViewController

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
		self.title = @"Status";
		self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Status" image:WAImg(@"My status") tag:1];
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.tableView.scrollEnabled = NO;
	CGFloat w = self.view.bounds.size.width;
	UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 260)];
	v.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	UIImageView *bubble = [[UIImageView alloc] initWithImage:SoonImage()];
	bubble.center = CGPointMake(floorf(w / 2), 112);
	bubble.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
	[v addSubview:bubble];
	UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(20, 196, w - 40, 26)];
	l.text = @"Coming in a later version";
	l.font = [UIFont boldSystemFontOfSize:19];
	l.textColor = WAColor(0x7F8A99);
	l.textAlignment = NSTextAlignmentCenter;
	l.backgroundColor = [UIColor clearColor];
	l.shadowColor = [UIColor whiteColor];
	l.shadowOffset = CGSizeMake(0, 1);
	l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[v addSubview:l];
	self.tableView.tableHeaderView = v;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return 0;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	return nil;
}

@end
