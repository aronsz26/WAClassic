#import <MediaPlayer/MediaPlayer.h>
#import "WAMediaViewController.h"
#import "WAClient.h"
#import "WAAssets.h"
#import "WAUtil.h"

#pragma mark - Viewer

@interface WAImageViewerController : UIViewController <UIScrollViewDelegate>
@property (nonatomic, strong) UIImageView *imageView;
@end

@implementation WAImageViewerController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = [UIColor blackColor];
	UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
	scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	scroll.maximumZoomScale = 4;
	scroll.delegate = self;
	self.imageView.frame = scroll.bounds;
	self.imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	self.imageView.contentMode = UIViewContentModeScaleAspectFit;
	[scroll addSubview:self.imageView];
	[self.view addSubview:scroll];
	[scroll addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)]];
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
	return self.imageView;
}

- (void)close {
	[[UIApplication sharedApplication] setStatusBarHidden:NO withAnimation:UIStatusBarAnimationFade];
	[self dismissViewControllerAnimated:YES completion:nil];
}

@end

@implementation WAMediaViewer

+ (void)showImageRequest:(NSURLRequest *)request placeholder:(UIImage *)placeholder from:(UIViewController *)vc {
	WAImageViewerController *viewer = [[WAImageViewerController alloc] init];
	viewer.imageView = [[UIImageView alloc] initWithImage:placeholder];
	viewer.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
	[vc presentViewController:viewer animated:YES completion:nil];
	[[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationFade];
	[[WAClient shared] load:request completion:^(NSData *data, NSInteger status, NSError *error) {
		UIImage *full = status == 200 ? [UIImage imageWithData:data] : nil;
		if (full) viewer.imageView.image = full;
	}];
}

+ (void)playVideoSeq:(long long)seq from:(UIViewController *)vc {
	NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"wa4s-video-%lld.mp4", seq]];
	void (^play)(void) = ^{
		MPMoviePlayerViewController *player = [[MPMoviePlayerViewController alloc] initWithContentURL:[NSURL fileURLWithPath:path]];
		[vc presentMoviePlayerViewControllerAnimated:player];
	};
	if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
		play();
		return;
	}
	[UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
	[[WAClient shared] load:[[WAClient shared] mediaRequestForSeq:seq format:@"mp4"] completion:^(NSData *data, NSInteger status, NSError *error) {
		[UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
		if (status != 200 || !data.length) return;
		[data writeToFile:path atomically:YES];
		play();
	}];
}

@end

#pragma mark - Grid

@implementation WAMediaViewController {
	NSString *_jid;
	UIScrollView *_scroll;
	NSArray *_items;
	UIView *_empty;
}

- (instancetype)initWithChat:(NSString *)jid title:(NSString *)title {
	if ((self = [super init])) {
		_jid = [jid copy];
		self.title = title;
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = [UIColor whiteColor];
	_scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
	_scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_scroll.alwaysBounceVertical = YES;
	[self.view addSubview:_scroll];
	[[WAClient shared] get:@"/api/chatmedia" params:@{@"chat": _jid} completion:^(id json, NSError *error) {
		self->_items = [json[@"media"] isKindOfClass:[NSArray class]] ? json[@"media"] : @[];
		[self layoutGrid];
	}];
}

// 4 per row, 4pt gap
- (void)layoutGrid {
	for (UIView *v in _scroll.subviews) [v removeFromSuperview];
	if (!_items.count) {
		UIImageView *iv = [[UIImageView alloc] initWithImage:WAImg(@"NoGroupMedia")];
		iv.center = CGPointMake(self.view.bounds.size.width / 2, 150);
		[_scroll addSubview:iv];
		UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(20, CGRectGetMaxY(iv.frame) + 10, self.view.bounds.size.width - 40, 24)];
		l.text = @"No Media";
		l.font = [UIFont boldSystemFontOfSize:17];
		l.textColor = WAColor(0x7F8A99);
		l.textAlignment = NSTextAlignmentCenter;
		l.backgroundColor = [UIColor clearColor];
		[_scroll addSubview:l];
		return;
	}
	CGFloat gap = 4, side = floorf((self.view.bounds.size.width - gap * 5) / 4);
	for (NSUInteger i = 0; i < _items.count; i++) {
		NSDictionary *item = _items[i];
		UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
		b.frame = CGRectMake(gap + (i % 4) * (side + gap), gap + (i / 4) * (side + gap), side, side);
		b.tag = (NSInteger)i;
		b.backgroundColor = [UIColor colorWithWhite:0.88 alpha:1];
		b.imageView.contentMode = UIViewContentModeScaleAspectFill;
		b.clipsToBounds = YES;
		[b addTarget:self action:@selector(open:) forControlEvents:UIControlEventTouchUpInside];
		[_scroll addSubview:b];
		if ([item[@"kind"] isEqualToString:@"video"]) {
			// duration strip
			UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, side - 16, side, 16)];
			bar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
			bar.userInteractionEnabled = NO;
			UILabel *len = [[UILabel alloc] initWithFrame:CGRectInset(bar.bounds, 4, 0)];
			NSInteger secs = [item[@"secs"] integerValue];
			len.text = [NSString stringWithFormat:@"%ld:%02ld", (long)(secs / 60), (long)(secs % 60)];
			len.textAlignment = NSTextAlignmentRight;
			len.font = [UIFont boldSystemFontOfSize:11];
			len.textColor = [UIColor whiteColor];
			len.backgroundColor = [UIColor clearColor];
			[bar addSubview:len];
			[b addSubview:bar];
		}
		[[WAClient shared] load:[[WAClient shared] mediaRequestForSeq:[item[@"seq"] longLongValue] format:@"thumb"]
			completion:^(NSData *data, NSInteger status, NSError *error) {
				UIImage *img = status == 200 ? [UIImage imageWithData:data] : nil;
				if (img) [b setImage:img forState:UIControlStateNormal];
			}];
	}
	NSUInteger rows = (_items.count + 3) / 4;
	_scroll.contentSize = CGSizeMake(self.view.bounds.size.width, gap + rows * (side + gap));
}

- (void)open:(UIButton *)b {
	NSDictionary *item = _items[(NSUInteger)b.tag];
	long long seq = [item[@"seq"] longLongValue];
	if ([item[@"kind"] isEqualToString:@"video"]) [WAMediaViewer playVideoSeq:seq from:self];
	else [WAMediaViewer showImageRequest:[[WAClient shared] mediaRequestForSeq:seq] placeholder:[b imageForState:UIControlStateNormal] from:self];
}

@end
