#import <AudioToolbox/AudioToolbox.h>
#import "WABanner.h"
#import "WAAssets.h"

@interface WABannerView : UIImageView
@property (nonatomic, copy) void (^tap)(void);
@end

@implementation WABannerView
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
	if (self.tap) self.tap();
	[UIView animateWithDuration:0.2 animations:^{ self.alpha = 0; } completion:^(BOOL done) { [self removeFromSuperview]; }];
}
@end

@implementation WABanner

static WABannerView *current;

+ (void)playSound {
	static SystemSoundID sound;
	if (!sound) {
		NSURL *url = [NSURL fileURLWithPath:WAAssetPath(@"Tri-tone.caf")];
		if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
			AudioServicesPlaySystemSound(1007); // fallback tri-tone
			return;
		}
		AudioServicesCreateSystemSoundID((__bridge CFURLRef)url, &sound);
	}
	AudioServicesPlaySystemSound(sound);
}

+ (void)showText:(NSString *)text inWindow:(UIWindow *)window onTap:(void (^)(void))tap {
	[current removeFromSuperview];
	CGFloat w = window.bounds.size.width;
	WABannerView *banner = [[WABannerView alloc] initWithFrame:CGRectMake(0, 20 - 44, w, 44)];
	UIImage *bg = WAStretch(@"NotificationBg", 0, 20, 0, 20);
	banner.image = bg;
	if (!bg) banner.backgroundColor = [UIColor colorWithWhite:0.95 alpha:0.97];
	banner.userInteractionEnabled = YES;
	banner.tap = tap;
	UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, w - 24, 42)];
	label.backgroundColor = [UIColor clearColor];
	label.font = [UIFont systemFontOfSize:14];
	label.numberOfLines = 2;
	label.text = text;
	[banner addSubview:label];
	[window addSubview:banner];
	current = banner;
	[self playSound];
	[UIView animateWithDuration:0.25 animations:^{
		banner.frame = CGRectMake(0, 20, w, 44);
	}];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		if (banner.superview == nil) return;
		[UIView animateWithDuration:0.25 animations:^{
			banner.frame = CGRectMake(0, 20 - 44, w, 44);
		} completion:^(BOOL done) {
			[banner removeFromSuperview];
			if (current == banner) current = nil;
		}];
	});
}

@end
