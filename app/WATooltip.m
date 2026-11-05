#import <QuartzCore/QuartzCore.h>
#import "WATooltip.h"
#import "WAAssets.h"

static const CGFloat kEdge = 9, kTop = 18, kBottom = 18, kArrow = 22;

@implementation WATooltip {
	UILabel *_label;
}

+ (WATooltip *)showText:(NSString *)text pointingAt:(CGPoint)point inView:(UIView *)view {
	CGFloat W = view.bounds.size.width, w = MIN(W - 16, 280);
	UIFont *font = [UIFont systemFontOfSize:13];
	CGSize ts = [text sizeWithFont:font constrainedToSize:CGSizeMake(w - 2 * kEdge - 4 - 30, 100) lineBreakMode:NSLineBreakByWordWrapping];
	CGFloat h = MAX(kTop + kBottom + 8, ceilf(ts.height) + 2 * kEdge + 20); // incl. arrow
	// keep it on screen
	CGFloat x = MIN(MAX(8, point.x - w + 46), W - 8 - w);
	WATooltip *t = [[WATooltip alloc] initWithFrame:CGRectMake(x, point.y - h, w, h) arrowAt:point.x - x text:text font:font];
	t.alpha = 0;
	[view addSubview:t];
	[UIView animateWithDuration:0.25 animations:^{ t.alpha = 1; }];
	return t;
}

- (instancetype)initWithFrame:(CGRect)frame arrowAt:(CGFloat)ax text:(NSString *)text font:(UIFont *)font {
	if ((self = [super initWithFrame:frame])) {
		self.backgroundColor = [UIColor clearColor];
		CGFloat w = frame.size.width, h = frame.size.height, mid = h - kTop - kBottom;
		ax = MIN(MAX(kEdge + kArrow / 2, ax), w - kEdge - kArrow / 2);
		if (WAImg(@"TT-CenterMiddle")) {
			// 9-slice, bottom split around the arrow
			[self piece:@"TT-LeftTop" frame:CGRectMake(0, 0, kEdge, kTop)];
			[self piece:@"TT-CenterTop" frame:CGRectMake(kEdge, 0, w - 2 * kEdge, kTop)];
			[self piece:@"TT-RightTop" frame:CGRectMake(w - kEdge, 0, kEdge, kTop)];
			[self piece:@"TT-LeftMiddle" frame:CGRectMake(0, kTop, kEdge, mid)];
			[self piece:@"TT-CenterMiddle" frame:CGRectMake(kEdge, kTop, w - 2 * kEdge, mid)];
			[self piece:@"TT-RightMiddle" frame:CGRectMake(w - kEdge, kTop, kEdge, mid)];
			CGFloat by = h - kBottom, al = ax - kArrow / 2;
			[self piece:@"TT-LeftBottom" frame:CGRectMake(0, by, kEdge, kBottom)];
			[self piece:@"TT-CenterBottom" frame:CGRectMake(kEdge, by, al - kEdge, kBottom)];
			[self piece:@"TT-ArrowBottom" frame:CGRectMake(al, by, kArrow, kBottom)];
			[self piece:@"TT-CenterBottom" frame:CGRectMake(al + kArrow, by, w - kEdge - al - kArrow, kBottom)];
			[self piece:@"TT-RightBottom" frame:CGRectMake(w - kEdge, by, kEdge, kBottom)];
		} else { // fallback
			UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h - 8)];
			box.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.92];
			box.layer.cornerRadius = 8;
			[self addSubview:box];
		}
		_label = [[UILabel alloc] initWithFrame:CGRectMake(kEdge + 4, 4, w - 2 * kEdge - 4 - 30, h - 8 - 8)];
		_label.text = text;
		_label.font = font;
		_label.numberOfLines = 0;
		_label.textColor = [UIColor whiteColor];
		_label.backgroundColor = [UIColor clearColor];
		_label.shadowColor = [UIColor colorWithWhite:0 alpha:0.6];
		_label.shadowOffset = CGSizeMake(0, -1);
		[self addSubview:_label];
		UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
		close.frame = CGRectMake(w - kEdge - 30, floorf((h - 8 - 30) / 2), 30, 30);
		UIImage *x = WAImg(@"TT-Close");
		if (x) {
			close.imageView.contentMode = UIViewContentModeCenter;
			[close setImage:x forState:UIControlStateNormal];
		} else {
			[close setTitle:@"✕" forState:UIControlStateNormal];
		}
		[close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
		[self addSubview:close];
	}
	return self;
}

// draw twice, one layer was too see-through
- (void)piece:(NSString *)name frame:(CGRect)frame {
	for (int i = 0; i < 2; i++) {
		UIImageView *iv = [[UIImageView alloc] initWithFrame:frame];
		iv.image = WAImg(name);
		iv.contentMode = UIViewContentModeScaleToFill;
		[self addSubview:iv];
	}
}

- (void)closeTapped {
	[self dismiss];
	if (self.onClose) self.onClose();
}

- (void)dismiss {
	[UIView animateWithDuration:0.2 animations:^{ self.alpha = 0; } completion:^(BOOL done) { [self removeFromSuperview]; }];
}

@end
