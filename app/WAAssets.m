#import "WAAssets.h"
#import "WAClient.h"
#import "WAUtil.h"
#import <AudioToolbox/AudioToolbox.h>

static NSString *const kAssetDir = @"/var/mobile/Library/WA4S/Assets";
static NSCache *imgCache;
static UIImage *Fallback(NSString *name);

NSString *WAAssetPath(NSString *file) {
	return [kAssetDir stringByAppendingPathComponent:file];
}

UIImage *WAImg(NSString *name) {
	if (!imgCache) imgCache = [[NSCache alloc] init];
	NSCache *cache = imgCache;
	UIImage *img = [cache objectForKey:name];
	if (!img) {
		NSData *data = nil;
		if ([UIScreen mainScreen].scale > 1) {
			data = [NSData dataWithContentsOfFile:WAAssetPath([name stringByAppendingString:@"@2x.png"])];
			if (data) img = [UIImage imageWithData:data scale:2];
		}
		if (!img) img = [UIImage imageWithContentsOfFile:WAAssetPath([name stringByAppendingPathExtension:@"png"])];
		if (!img) img = Fallback(name);
		if (img) [cache setObject:img forKey:name];
	}
	return img;
}

UIImage *WAReadTick(void) {
	UIImage *src = WAImg(@"mark_d");
	UIImage *img = [imgCache objectForKey:@"mark_read"];
	if (img || !src) return img ?: src;
	CGRect r = {CGPointZero, src.size};
	UIGraphicsBeginImageContextWithOptions(src.size, NO, src.scale);
	[src drawInRect:r];
	// keeps the shading of the original tick
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	CGContextSetBlendMode(ctx, kCGBlendModeHue);
	[WAColor(0x1E90FF) setFill];
	CGContextFillRect(ctx, r);
	[src drawInRect:r blendMode:kCGBlendModeDestinationIn alpha:1];
	img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	if (img) [imgCache setObject:img forKey:@"mark_read"];
	return img ?: src;
}

UIImage *WASystemImg(NSString *base) {
	NSArray *suffixes = [UIScreen mainScreen].scale > 1 ? @[@"@2x~iphone.png", @"@2x.png", @"~iphone.png", @".png"]
		: @[@"~iphone.png", @".png", @"@2x~iphone.png", @"@2x.png"];
	for (NSString *suffix in suffixes) {
		NSData *data = [NSData dataWithContentsOfFile:[base stringByAppendingString:suffix]];
		if (data) return [UIImage imageWithData:data scale:[suffix hasPrefix:@"@2x"] ? 2 : 1];
	}
	return nil;
}

UIImage *WAStretch(NSString *name, CGFloat top, CGFloat left, CGFloat bottom, CGFloat right) {
	return [WAImg(name) resizableImageWithCapInsets:UIEdgeInsetsMake(top, left, bottom, right)];
}

#pragma mark - From the bridge

// springboard only reads launch image + sounds from the app bundle and ignores symlinks.
// postinst chowns them to mobile so we can fill them in
static NSArray *BundleCopies(void) {
	return @[@"Default.png", @"Default@2x.png", @"Default-568h@2x.png", @"Tri-tone.caf", @"Ringtone.caf",
		@"Xylophone.caf", @"Bell.caf", @"Boing.caf", @"Glass.caf", @"Harp.caf", @"TimePassing.caf"];
}

static void CopyIntoBundle(void) {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *bundle = [[NSBundle mainBundle] bundlePath];
	for (NSString *file in BundleCopies()) {
		NSData *data = [NSData dataWithContentsOfFile:WAAssetPath(file)];
		NSString *dst = [bundle stringByAppendingPathComponent:file];
		NSDictionary *attrs = [fm attributesOfItemAtPath:dst error:NULL];
		if (!data.length || ![attrs.fileType isEqualToString:NSFileTypeRegular] || ![fm isWritableFileAtPath:dst]) continue;
		if ([[NSData dataWithContentsOfFile:dst] isEqualToData:data]) continue;
		// write in place, can't create files in the root owned app folder
		NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:dst];
		[out truncateFileAtOffset:0];
		[out writeData:data];
		[out closeFile];
		WALog(@"assets: %@ copied into the app", file);
	}
}

NSString *WABundleFile(NSString *file) {
	NSString *path = [[NSBundle mainBundle] pathForResource:file.stringByDeletingPathExtension ofType:file.pathExtension];
	NSDictionary *attrs = path ? [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL] : nil;
	return attrs.fileSize > 0 ? path : nil; // empty placeholders
}

// Ringtone.caf: ring.m4r as IMA4 (no AAC for notif sounds), looped to ~30s
static void MakeRingtone(void) {
	NSString *dst = WAAssetPath(@"Ringtone.caf");
	if ([[NSFileManager defaultManager] fileExistsAtPath:dst]) {
		CopyIntoBundle();
		return;
	}
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
		NSURL *src = [NSURL fileURLWithPath:@"/System/Library/CoreServices/SpringBoard.app/ring.m4r"];
		NSString *tmp = [dst stringByAppendingString:@".part"];
		AudioStreamBasicDescription pcm = {0};
		pcm.mSampleRate = 22050;
		pcm.mFormatID = kAudioFormatLinearPCM;
		pcm.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
		pcm.mChannelsPerFrame = 1;
		pcm.mBitsPerChannel = 16;
		pcm.mBytesPerFrame = pcm.mBytesPerPacket = 2;
		pcm.mFramesPerPacket = 1;
		ExtAudioFileRef in = NULL, out = NULL;
		NSMutableData *samples = [NSMutableData data];
		if (ExtAudioFileOpenURL((__bridge CFURLRef)src, &in) == noErr &&
			ExtAudioFileSetProperty(in, kExtAudioFileProperty_ClientDataFormat, sizeof(pcm), &pcm) == noErr) {
			char buf[16384];
			while (samples.length < 30 * 22050 * 2) {
				AudioBufferList list = {1, {{1, sizeof(buf), buf}}};
				UInt32 frames = sizeof(buf) / 2;
				if (ExtAudioFileRead(in, &frames, &list) != noErr || !frames) break;
				[samples appendBytes:buf length:frames * 2];
			}
		}
		if (in) ExtAudioFileDispose(in);
		UInt32 frames = (UInt32)(samples.length / 2);
		BOOL ok = frames > 0;
		AudioStreamBasicDescription ima = {0};
		ima.mSampleRate = 22050;
		ima.mFormatID = kAudioFormatAppleIMA4;
		ima.mChannelsPerFrame = 1;
		ima.mFramesPerPacket = 64;
		ima.mBytesPerPacket = 34;
		[[NSFileManager defaultManager] createDirectoryAtPath:kAssetDir withIntermediateDirectories:YES attributes:nil error:NULL];
		ok = ok && ExtAudioFileCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:tmp], kAudioFileCAFType, &ima, NULL,
			kAudioFileFlags_EraseFile, &out) == noErr &&
			ExtAudioFileSetProperty(out, kExtAudioFileProperty_ClientDataFormat, sizeof(pcm), &pcm) == noErr;
		for (UInt32 i = 0, times = MAX(1, 29 * 22050 / MAX(frames, 1)); ok && i < times; i++) {
			AudioBufferList list = {1, {{1, (UInt32)samples.length, (void *)samples.bytes}}};
			ok = ExtAudioFileWrite(out, frames, &list) == noErr;
		}
		if (out) ExtAudioFileDispose(out);
		ok = ok && [[NSFileManager defaultManager] moveItemAtPath:tmp toPath:dst error:NULL];
		if (!ok) [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
		dispatch_async(dispatch_get_main_queue(), ^{
			WALog(@"assets: ringtone %@", ok ? @"made" : @"failed");
			CopyIntoBundle(); // the other sounds don't need the ringtone
		});
	});
}

static BOOL SafeName(NSString *name) {
	return [name isKindOfClass:[NSString class]] && name.length && ![name hasPrefix:@"/"] &&
		[name rangeOfString:@".."].location == NSNotFound;
}

// one by one (3gs memory), stop at first error
static void FetchNext(NSMutableArray *queue, NSUInteger fetched, void (^finish)(NSUInteger fetched)) {
	if (!queue.count) {
		finish(fetched);
		return;
	}
	NSString *name = queue[0];
	[queue removeObjectAtIndex:0];
	WAClient *client = [WAClient shared];
	[client load:[client requestFor:@"/api/assets/file" params:@{@"name": name}]
		completion:^(NSData *data, NSInteger status, NSError *error) {
		NSString *path = WAAssetPath(name);
		[[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
			withIntermediateDirectories:YES attributes:nil error:NULL];
		if (error || status != 200 || !data.length || ![data writeToFile:path atomically:YES]) {
			WALog(@"assets: %@ failed (%ld %@)", name, (long)status, error.localizedDescription);
			finish(fetched);
			return;
		}
		FetchNext(queue, fetched + 1, finish);
	}];
}

void WAAssetsSync(void (^changed)(void)) {
	static BOOL running;
	if (running || ![WAClient shared].configured) return;
	running = YES;
	[[WAClient shared] get:@"/api/assets" params:nil completion:^(id json, NSError *error) {
		NSArray *files = [json isKindOfClass:[NSDictionary class]] ? json[@"files"] : nil;
		NSMutableArray *queue = [NSMutableArray array];
		NSFileManager *fm = [NSFileManager defaultManager];
		for (NSDictionary *file in [files isKindOfClass:[NSArray class]] ? files : nil) {
			NSString *name = [file isKindOfClass:[NSDictionary class]] ? file[@"name"] : nil;
			if (!SafeName(name)) continue;
			NSDictionary *attrs = [fm attributesOfItemAtPath:WAAssetPath(name) error:NULL];
			if (!attrs || attrs.fileSize != [file[@"size"] unsignedLongLongValue]) [queue addObject:name];
		}
		if (queue.count) WALog(@"assets: %lu files from the bridge", (unsigned long)queue.count);
		else if (!files) WALog(@"assets: the bridge has none yet (%@)", json[@"state"] ?: error.localizedDescription);
		FetchNext(queue, 0, ^(NSUInteger fetched) {
			running = NO;
			MakeRingtone();
			if (!fetched) return;
			WALog(@"assets: %lu files loaded", (unsigned long)fetched);
			[imgCache removeAllObjects];
			if (changed) changed();
		});
	}];
}

#pragma mark - Plain drawings

// stand-ins in original sizes. stuff with its own fallback stays nil

static UIImage *Draw(CGSize size, void (^draw)(CGContextRef ctx)) {
	UIGraphicsBeginImageContextWithOptions(size, NO, 0);
	draw(UIGraphicsGetCurrentContext());
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

// mirror for incoming
static CGPoint P(CGFloat x, CGFloat y, BOOL mirror) { return CGPointMake(mirror ? 40 - x : x, y); }

static UIImage *Bubble(BOOL mine) {
	return Draw(CGSizeMake(40, 30), ^(CGContextRef ctx) {
		// caps 10/15/19/24, keep those rows/cols plain
		UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(mine ? 1.5 : 7.5, 1, 31, 26) cornerRadius:9];
		UIBezierPath *tail = [UIBezierPath bezierPath]; // tail
		[tail moveToPoint:P(26, 27, !mine)];
		[tail addQuadCurveToPoint:P(38.5, 27.5, !mine) controlPoint:P(33, 27.5, !mine)];
		[tail addQuadCurveToPoint:P(32, 17, !mine) controlPoint:P(32.5, 24, !mine)];
		[tail closePath];
		[path appendPath:tail];
		CGContextSetShadowWithColor(ctx, CGSizeMake(0, 1), 1, [UIColor colorWithWhite:0 alpha:0.35].CGColor);
		[WAColor(mine ? 0xDCF8C6 : 0xFFFFFF) setFill];
		[path fill];
	});
}

static UIImage *Ticks(int count, UIColor *color) {
	return Draw(CGSizeMake(15, 12), ^(CGContextRef ctx) {
		UIBezierPath *path = [UIBezierPath bezierPath];
		for (int i = 0; i < count; i++) {
			CGFloat dx = count == 2 ? i * 4 - 1.5 : 0;
			[path moveToPoint:CGPointMake(2.5 + dx, 6.5)];
			[path addLineToPoint:CGPointMake(5.5 + dx, 9.5)];
			[path addLineToPoint:CGPointMake(11.5 + dx, 2.5)];
		}
		path.lineWidth = 1.6;
		path.lineCapStyle = kCGLineCapRound;
		path.lineJoinStyle = kCGLineJoinRound;
		[color setStroke];
		[path stroke];
	});
}

static void Person(CGRect r, UIColor *color) {
	CGFloat w = r.size.width;
	[color setFill];
	[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(r.origin.x + w * 0.32, r.origin.y + w * 0.2, w * 0.36, w * 0.36)] fill];
	[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(r.origin.x + w * 0.16, r.origin.y + w * 0.6, w * 0.68, w * 0.6)] fill];
}

static UIImage *Avatar(CGFloat size, BOOL group) {
	return Draw(CGSizeMake(size, size), ^(CGContextRef ctx) {
		CGRect r = CGRectMake(0, 0, size, size);
		[WAColor(0xD3D7DC) setFill];
		UIRectFill(r);
		UIRectClip(r);
		UIColor *white = [UIColor whiteColor];
		if (!group) Person(r, white);
		else {
			Person(CGRectMake(-size * 0.17, size * 0.08, size * 0.75, size * 0.75), [UIColor colorWithWhite:1 alpha:0.75]);
			Person(CGRectMake(size * 0.42, size * 0.08, size * 0.75, size * 0.75), [UIColor colorWithWhite:1 alpha:0.75]);
			Person(CGRectMake(size * 0.12, size * 0.22, size * 0.76, size * 0.76), white);
		}
	});
}

static UIImage *Mic(UIColor *color) {
	return Draw(CGSizeMake(13, 18), ^(CGContextRef ctx) {
		[color set];
		[[UIBezierPath bezierPathWithRoundedRect:CGRectMake(4, 1, 5, 10) cornerRadius:2.5] fill];
		UIBezierPath *stand = [UIBezierPath bezierPathWithArcCenter:CGPointMake(6.5, 8) radius:4.5 startAngle:0 endAngle:M_PI clockwise:YES];
		[stand moveToPoint:CGPointMake(6.5, 12.5)];
		[stand addLineToPoint:CGPointMake(6.5, 16)];
		[stand moveToPoint:CGPointMake(4, 16.5)];
		[stand addLineToPoint:CGPointMake(9, 16.5)];
		stand.lineWidth = 1.3;
		[stand stroke];
	});
}

static UIImage *Field(CGSize size, CGFloat radius) {
	return Draw(size, ^(CGContextRef ctx) {
		UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.5, 0.5, size.width - 1, size.height - 1.5)
			cornerRadius:radius];
		[[UIColor whiteColor] setFill];
		[path fill];
		[WAColor(0xA6ABB3) setStroke];
		[path stroke];
	});
}

static UIImage *RedButton(BOOL pressed) {
	return Draw(CGSizeMake(21, 44), ^(CGContextRef ctx) {
		UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.5, 0.5, 20, 43) cornerRadius:8];
		[WAColor(pressed ? 0xA3241C : 0xD33A30) setFill];
		[path fill];
		[WAColor(0x8C1A13) setStroke];
		[path stroke];
		[[UIColor colorWithWhite:1 alpha:pressed ? 0.08 : 0.18] setFill];
		[[UIBezierPath bezierPathWithRoundedRect:CGRectMake(1, 1, 19, 21) cornerRadius:7.5] fill]; // ios 6 gloss
	});
}

// tab icons, alpha only
static UIImage *TabIcon(NSString *name) {
	return Draw(CGSizeMake(30, 30), ^(CGContextRef ctx) {
		[[UIColor blackColor] set];
		if ([name isEqualToString:@"Chats"]) {
			UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 4, 26, 18) cornerRadius:8];
			[path moveToPoint:CGPointMake(7, 20)];
			[path addLineToPoint:CGPointMake(5, 28)];
			[path addLineToPoint:CGPointMake(14, 21)];
			[path fill];
		} else if ([name isEqualToString:@"Settings"]) {
			CGContextTranslateCTM(ctx, 15, 15);
			for (int i = 0; i < 8; i++) {
				[[UIBezierPath bezierPathWithRoundedRect:CGRectMake(-2.5, -13, 5, 7) cornerRadius:1] fill];
				CGContextRotateCTM(ctx, M_PI / 4);
			}
			[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(-9.5, -9.5, 19, 19)] fill];
			CGContextSetBlendMode(ctx, kCGBlendModeClear);
			[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(-4, -4, 8, 8)] fill];
		} else { // status icon
			[[UIBezierPath bezierPathWithRoundedRect:CGRectMake(5, 3, 20, 24) cornerRadius:3] fill];
			CGContextSetBlendMode(ctx, kCGBlendModeClear);
			for (int i = 0; i < 4; i++) UIRectFill(CGRectMake(9, 8 + i * 4.5, i == 3 ? 7 : 12, 2));
		}
	});
}

static UIImage *Fallback(NSString *name) {
	static NSDictionary *makers;
	if (!makers) makers = @{
		@"GreenBubbleOut": ^{ return Bubble(YES); },
		@"GrayBubbleIn": ^{ return Bubble(NO); },
		@"mark_s": ^{ return Ticks(1, WAColor(0x4CAF50)); },
		@"mark_d": ^{ return Ticks(2, WAColor(0x4CAF50)); },
		@"BrdtCheck": ^{ return Ticks(1, WAColor(0x4CAF50)); },
		@"BrdtDoubleCheck": ^{ return Ticks(2, WAColor(0x4CAF50)); },
		@"GrayClockIcon": ^{ return Draw(CGSizeMake(15, 12), ^(CGContextRef ctx) {
			UIBezierPath *path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(3, 1.5, 9, 9)];
			[path moveToPoint:CGPointMake(7.5, 3.5)];
			[path addLineToPoint:CGPointMake(7.5, 6)];
			[path addLineToPoint:CGPointMake(9.5, 7)];
			path.lineWidth = 1.1;
			[WAColor(0x999999) setStroke];
			[path stroke];
		}); },
		@"Chats": ^{ return TabIcon(@"Chats"); },
		@"Settings": ^{ return TabIcon(@"Settings"); },
		@"My status": ^{ return TabIcon(@"My status"); },
		@"EmptyContact": ^{ return Avatar(62, NO); },
		@"GroupChat": ^{ return Avatar(56, YES); },
		@"MicIncoming": ^{ return Mic(WAColor(0x8A8A8A)); },
		@"MicOutgoing": ^{ return Mic(WAColor(0x6E9A5A)); },
		@"MicChats": ^{ return Mic(WAColor(0x8A8A8A)); },
		@"MicChatsBlue": ^{ return Mic(WAColor(0x3E88D8)); },
		@"ChatInputControlsBG": ^{ return Draw(CGSizeMake(2, 40), ^(CGContextRef ctx) {
			CGFloat colors[] = {0.95, 0.955, 0.96, 1, 0.84, 0.85, 0.87, 1};
			CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
			CGGradientRef gradient = CGGradientCreateWithColorComponents(space, colors, NULL, 2);
			CGContextDrawLinearGradient(ctx, gradient, CGPointZero, CGPointMake(0, 40), 0);
			CGGradientRelease(gradient);
			CGColorSpaceRelease(space);
			[WAColor(0xA5A9B0) setFill];
			UIRectFill(CGRectMake(0, 0, 2, 0.5));
		}); },
		@"ChatInputFieldBG": ^{ return Draw(CGSizeMake(40, 40), ^(CGContextRef ctx) {
			UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(4.5, 8.5, 31, 24) cornerRadius:12];
			[[UIColor whiteColor] setFill];
			[path fill];
			[WAColor(0xA6ABB3) setStroke];
			[path stroke];
		}); },
		@"TextFieldBg": ^{ return Field(CGSizeMake(75, 45), 8); },
		@"RedButton": ^{ return RedButton(NO); },
		@"RedButtonPressed": ^{ return RedButton(YES); },
		@"VideoOverlayPlay": ^{ return Draw(CGSizeMake(72, 72), ^(CGContextRef ctx) {
			UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(12, 12, 48, 48)];
			[[UIColor colorWithWhite:0 alpha:0.45] setFill];
			[circle fill];
			circle.lineWidth = 2;
			[[UIColor whiteColor] set];
			[circle stroke];
			UIBezierPath *play = [UIBezierPath bezierPath];
			[play moveToPoint:CGPointMake(30, 25)];
			[play addLineToPoint:CGPointMake(47, 36)];
			[play addLineToPoint:CGPointMake(30, 47)];
			[play closePath];
			[play fill];
		}); },
		@"MuteIndicator": ^{ return Draw(CGSizeMake(15, 17), ^(CGContextRef ctx) {
			[WAColor(0x9A9A9A) set];
			UIBezierPath *speaker = [UIBezierPath bezierPath];
			[speaker moveToPoint:CGPointMake(2, 6.5)];
			[speaker addLineToPoint:CGPointMake(5, 6.5)];
			[speaker addLineToPoint:CGPointMake(9, 3)];
			[speaker addLineToPoint:CGPointMake(9, 14)];
			[speaker addLineToPoint:CGPointMake(5, 10.5)];
			[speaker addLineToPoint:CGPointMake(2, 10.5)];
			[speaker closePath];
			[speaker fill];
			UIBezierPath *slash = [UIBezierPath bezierPath];
			[slash moveToPoint:CGPointMake(1.5, 2.5)];
			[slash addLineToPoint:CGPointMake(13.5, 14.5)];
			slash.lineWidth = 1.4;
			[slash stroke];
		}); },
		@"Pen": ^{ return Draw(CGSizeMake(17, 15), ^(CGContextRef ctx) {
			[[UIColor blackColor] set];
			UIRectFrame(CGRectMake(1, 3, 11, 11));
			CGContextTranslateCTM(ctx, 11, 6);
			CGContextRotateCTM(ctx, M_PI / 4);
			UIRectFill(CGRectMake(-1.5, -6, 3, 9));
			UIBezierPath *tip = [UIBezierPath bezierPath];
			[tip moveToPoint:CGPointMake(-1.5, 3.5)];
			[tip addLineToPoint:CGPointMake(1.5, 3.5)];
			[tip addLineToPoint:CGPointMake(0, 6)];
			[tip closePath];
			[tip fill];
		}); },
	};
	UIImage *(^make)(void) = makers[name];
	return make ? make() : nil;
}
