#import "WABubbles.h"
#import "WAAssets.h"
#import "WAUtil.h"

NSArray *WABubbleColorNames(void) {
	return @[@"Green", @"White", @"Blue", @"Teal", @"Purple", @"Pink", @"Red", @"Orange", @"Yellow", @"Gray"];
}

static unsigned ColorHex(NSString *name) {
	NSDictionary *hex = @{@"Green": @0xDCF8C6, @"White": @0xFFFFFF, @"Blue": @0x9CC9F7, @"Teal": @0x9FE3DD,
		@"Purple": @0xD3B8F0, @"Pink": @0xF8BBD9, @"Red": @0xF7A8A4, @"Orange": @0xFFCC8A, @"Yellow": @0xFFEC8C,
		@"Gray": @0xD0D3D8};
	return [hex[name] ?: @0xDCF8C6 unsignedIntValue];
}

UIColor *WABubbleFill(NSString *name, BOOL mine) {
	if (!name) name = mine ? @"Green" : @"White";
	return WAColor(ColorHex(name));
}

// grey bubble * color, masked to the shape
static UIImage *Tinted(UIImage *src, UIColor *color) {
	CGRect r = CGRectMake(0, 0, src.size.width, src.size.height);
	UIGraphicsBeginImageContextWithOptions(r.size, NO, src.scale);
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	[src drawInRect:r];
	CGContextSetBlendMode(ctx, kCGBlendModeSaturation);
	[[UIColor grayColor] setFill];
	CGContextFillRect(ctx, r);
	// lift the grey back to white so colors stay clean
	CGContextSetBlendMode(ctx, kCGBlendModeScreen);
	[[UIColor colorWithWhite:0.12 alpha:1] setFill];
	CGContextFillRect(ctx, r);
	CGContextSetBlendMode(ctx, kCGBlendModeMultiply);
	[color setFill];
	CGContextFillRect(ctx, r);
	[src drawInRect:r blendMode:kCGBlendModeDestinationIn alpha:1];
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

static NSCache *cache;

void WABubblesReset(void) {
	[cache removeAllObjects];
}

UIImage *WABubbleImage(NSString *name, BOOL mine) {
	if (!cache) cache = [[NSCache alloc] init];
	if (!name) name = mine ? @"Green" : @"White";
	NSString *key = [name stringByAppendingString:mine ? @"-out" : @"-in"];
	UIImage *img = [cache objectForKey:key];
	if (img) return img;
	UIImage *src = WAImg(mine ? @"GreenBubbleOut" : @"GrayBubbleIn");
	if (!src) return nil;
	BOOL original = [name isEqualToString:mine ? @"Green" : @"White"];
	img = original ? src : Tinted(src, WABubbleFill(name, mine));
	UIEdgeInsets caps = mine ? UIEdgeInsetsMake(10, 15, 19, 24) : UIEdgeInsetsMake(10, 24, 19, 15);
	img = [img resizableImageWithCapInsets:caps];
	[cache setObject:img forKey:key];
	return img;
}

UIImage *WABubbleSwatch(NSString *name, BOOL mine) {
	CGRect r = CGRectMake(0, 0, 46, 30);
	UIGraphicsBeginImageContextWithOptions(r.size, NO, 0);
	UIImage *bubble = WABubbleImage(name, mine);
	if (bubble) {
		[bubble drawInRect:r];
	} else {
		[WABubbleFill(name, mine) setFill];
		[[UIBezierPath bezierPathWithRoundedRect:CGRectInset(r, 2, 2) cornerRadius:10] fill];
	}
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}
