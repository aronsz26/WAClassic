// WACompat4 - ios 5 APIs for the ios 4 build (WA_IOS4)
// only added if missing. theming calls are no-ops on ios 4 (logged once)
#ifdef WA_IOS4
#import <UIKit/UIKit.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - appearance proxy that swallows everything

@interface WASwallowProxy : NSProxy
@property (nonatomic, assign) Class target;
@end

@implementation WASwallowProxy

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
	NSMethodSignature *sig = [self.target instanceMethodSignatureForSelector:sel];
	if (sig) return sig;
	// generic ios 5 setter stub, all args are 4 bytes on armv7
	NSString *name = NSStringFromSelector(sel);
	NSUInteger args = [[name componentsSeparatedByString:@":"] count] - 1;
	NSMutableString *types = [NSMutableString stringWithString:@"v@:"];
	for (NSUInteger i = 0; i < args; i++) [types appendString:@"@"];
	return [NSMethodSignature signatureWithObjCTypes:types.UTF8String];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
	// no appearance proxies on ios 4
}

@end

static id WAAppearance(id cls, SEL _cmd) {
	WASwallowProxy *p = [WASwallowProxy alloc];
	p.target = cls;
	return p;
}

static id WAAppearanceWhenContainedIn(id cls, SEL _cmd, Class container, ...) {
	return WAAppearance(cls, _cmd);
}

#pragma mark - theming setters that don't exist on iOS 4

static void WANoOp(id self, SEL _cmd, ...) {
	static NSMutableSet *logged;
	NSString *key = [NSString stringWithFormat:@"%s %s", class_getName(object_getClass(self)), sel_getName(_cmd)];
	@synchronized ([NSObject class]) {
		if (!logged) logged = [NSMutableSet set];
		if ([logged containsObject:key]) return;
		[logged addObject:key];
	}
	NSLog(@"[WA4S iOS4] no-op: -[%@]", key);
}

static id WANil(id self, SEL _cmd) { return nil; }
static BOOL WANo(id self, SEL _cmd) { return NO; }

static void WAAdd(Class cls, NSString *selName, IMP imp, const char *types) {
	SEL sel = NSSelectorFromString(selName);
	if (!cls || [cls instancesRespondToSelector:sel]) return;
	class_addMethod(cls, sel, imp, types);
}

static void WAAddSetters(Class cls, NSArray *names) {
	for (NSString *name in names) {
		NSUInteger args = [[name componentsSeparatedByString:@":"] count] - 1;
		char types[16] = "v@:";
		for (NSUInteger i = 0; i < args && i < 8; i++) strcat(types, "@");
		WAAdd(cls, name, (IMP)WANoOp, types);
	}
}

#pragma mark - view controllers: present / dismiss with completion

static void WARunLater(BOOL animated, void (^completion)(void)) {
	if (!completion) return;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((animated ? 0.45 : 0.05) * NSEC_PER_SEC)),
	               dispatch_get_main_queue(), completion);
}

static void WAPresent(UIViewController *self, SEL _cmd, UIViewController *vc, BOOL animated, void (^completion)(void)) {
	[self presentModalViewController:vc animated:animated];
	WARunLater(animated, completion);
}

static void WADismiss(UIViewController *self, SEL _cmd, BOOL animated, void (^completion)(void)) {
	[self dismissModalViewControllerAnimated:animated];
	WARunLater(animated, completion);
}

static UIViewController *WAPresented(UIViewController *self, SEL _cmd) {
	return self.modalViewController;
}

static UIViewController *WAPresenting(UIViewController *self, SEL _cmd) {
	UIViewController *p = self.parentViewController;
	return p.modalViewController == self || p.modalViewController == self.navigationController ? p : nil;
}

#pragma mark - UITabBarItem (finished images)

// ios 4 tab icons are masks only
static void WASetFinishedImages(UITabBarItem *self, SEL _cmd, UIImage *selected, UIImage *unselected) {
	self.image = unselected ?: selected;
}

#pragma mark - UIImage

static UIImage *WAResizable(UIImage *self, SEL _cmd, UIEdgeInsets insets) {
	return [self stretchableImageWithLeftCapWidth:(NSInteger)insets.left topCapHeight:(NSInteger)insets.top];
}

#pragma mark - NSURLConnection (+sendAsynchronousRequest:queue:completionHandler:)

// use WALegacyRequest, sendSynchronousRequest hides the 401 response on ios 4
// (we need the Date header for clock skew)
@interface NSObject (WALegacyRequest)
- (void)start:(NSURLRequest *)request completion:(void (^)(NSURLResponse *, NSData *, NSError *))done;
@end

static void WASendAsync(id cls, SEL _cmd, NSURLRequest *request, NSOperationQueue *queue,
                        void (^handler)(NSURLResponse *, NSData *, NSError *)) {
	void (^h)(NSURLResponse *, NSData *, NSError *) = [handler copy];
	void (^start)(void) = ^{
		[[[NSClassFromString(@"WALegacyRequest") alloc] init] start:request completion:^(NSURLResponse *response, NSData *data, NSError *error) {
			if (!h) return;
			if (!queue || queue == [NSOperationQueue mainQueue]) h(response, data, error);
			else [queue addOperationWithBlock:^{ h(response, data, error); }];
		}];
	};
	if ([NSThread isMainThread]) start();
	else dispatch_async(dispatch_get_main_queue(), start);
}

#pragma mark - MPMediaItemArtwork (-initWithImage:, iOS 5)

// no now playing info on ios 4, empty artwork is fine
static id WAArtworkInitWithImage(id self, SEL _cmd, UIImage *image) {
	return [self init];
}


#pragma mark - NSValue (UIOffset), UIColor components

static NSValue *WAValueWithUIOffset(id cls, SEL _cmd, UIOffset o) {
	return [NSValue valueWithBytes:&o objCType:@encode(UIOffset)];
}

static UIOffset WAUIOffsetValue(NSValue *self, SEL _cmd) {
	UIOffset o = { 0, 0 };
	[self getValue:&o];
	return o;
}

static BOOL WAGetRGBA(UIColor *self, SEL _cmd, CGFloat *r, CGFloat *g, CGFloat *b, CGFloat *a) {
	CGColorRef c = self.CGColor;
	const CGFloat *v = CGColorGetComponents(c);
	CGColorSpaceModel m = CGColorSpaceGetModel(CGColorGetColorSpace(c));
	if (m == kCGColorSpaceModelRGB) {
		if (r) *r = v[0]; if (g) *g = v[1]; if (b) *b = v[2]; if (a) *a = v[3];
		return YES;
	}
	if (m == kCGColorSpaceModelMonochrome) {
		if (r) *r = v[0]; if (g) *g = v[0]; if (b) *b = v[0]; if (a) *a = v[1];
		return YES;
	}
	return NO;
}

static BOOL WAGetWhite(UIColor *self, SEL _cmd, CGFloat *w, CGFloat *a) {
	CGColorRef c = self.CGColor;
	if (CGColorSpaceGetModel(CGColorGetColorSpace(c)) != kCGColorSpaceModelMonochrome) return NO;
	const CGFloat *v = CGColorGetComponents(c);
	if (w) *w = v[0];
	if (a) *a = v[1];
	return YES;
}

#pragma mark - UITableView

static NSArray *WASelectedRows(UITableView *self, SEL _cmd) {
	NSIndexPath *ip = [self indexPathForSelectedRow];
	return ip ? @[ ip ] : nil;
}

// no animated move on ios 4, delete + insert
static void WAMoveRow(UITableView *self, SEL _cmd, NSIndexPath *from, NSIndexPath *to) {
	[self beginUpdates];
	[self deleteRowsAtIndexPaths:@[ from ] withRowAnimation:UITableViewRowAnimationFade];
	[self insertRowsAtIndexPaths:@[ to ] withRowAnimation:UITableViewRowAnimationFade];
	[self endUpdates];
}

#pragma mark - UIAlertView with text fields (alertViewStyle, textFieldAtIndex:)

static char WAAlertStyleKey, WAAlertFieldsKey;
static IMP WAAlertShowOriginal;

static UIAlertViewStyle WAAlertStyle(UIAlertView *self, SEL _cmd) {
	return (UIAlertViewStyle)[objc_getAssociatedObject(self, &WAAlertStyleKey) integerValue];
}

static UITextField *WAAlertField(BOOL secure, NSString *placeholder) {
	UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 252, 28)];
	f.borderStyle = UITextBorderStyleRoundedRect;
	f.secureTextEntry = secure;
	f.placeholder = placeholder;
	f.autocorrectionType = UITextAutocorrectionTypeNo;
	f.autocapitalizationType = UITextAutocapitalizationTypeNone;
	f.font = [UIFont systemFontOfSize:15];
	return f;
}

static void WASetAlertStyle(UIAlertView *self, SEL _cmd, UIAlertViewStyle style) {
	objc_setAssociatedObject(self, &WAAlertStyleKey, @(style), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	NSArray *fields = nil;
	if (style == UIAlertViewStyleSecureTextInput) fields = @[ WAAlertField(YES, nil) ];
	else if (style == UIAlertViewStylePlainTextInput) fields = @[ WAAlertField(NO, nil) ];
	else if (style == UIAlertViewStyleLoginAndPasswordInput) fields = @[ WAAlertField(NO, @"Login"), WAAlertField(YES, @"Password") ];
	objc_setAssociatedObject(self, &WAAlertFieldsKey, fields, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UITextField *WATextFieldAtIndex(UIAlertView *self, SEL _cmd, NSInteger index) {
	NSArray *fields = objc_getAssociatedObject(self, &WAAlertFieldsKey);
	return index >= 0 && index < (NSInteger)fields.count ? fields[(NSUInteger)index] : nil;
}

// fake text fields: room in the message, fields above the buttons
static void WAAlertShow(UIAlertView *self, SEL _cmd) {
	NSArray *fields = objc_getAssociatedObject(self, &WAAlertFieldsKey);
	if (fields.count) {
		NSMutableString *m = [NSMutableString stringWithString:self.message ?: @""];
		for (NSUInteger i = 0; i < fields.count; i++) [m appendString:@"\n\n"];
		self.message = m;
	}
	((void (*)(id, SEL))WAAlertShowOriginal)(self, _cmd);
	if (!fields.count) return;
	dispatch_async(dispatch_get_main_queue(), ^{
		CGFloat buttonsTop = self.bounds.size.height - 60;
		for (UIView *v in self.subviews)
			if ([v isKindOfClass:[UIControl class]] && ![v isKindOfClass:[UITextField class]] && v.frame.origin.y > 40)
				buttonsTop = MIN(buttonsTop, v.frame.origin.y);
		CGFloat y = buttonsTop - 8 - 34 * fields.count;
		for (UITextField *f in fields) {
			f.frame = CGRectMake((self.bounds.size.width - 252) / 2, y, 252, 28);
			[self addSubview:f];
			y += 34;
		}
		[fields[0] becomeFirstResponder];
	});
}

#pragma mark - single taps leave controls alone (iOS 6 behaviour)

// ios 4 lets tap recognizers eat taps on controls (setup's Connect button),
// so ignore touches that start in a control
static IMP WATapTouchesBeganOriginal;

static void WATapTouchesBegan(UITapGestureRecognizer *self, SEL _cmd, NSSet *touches, UIEvent *event) {
	if (self.numberOfTapsRequired == 1) {
		for (UITouch *t in touches) {
			for (UIView *v = t.view; v && v != self.view; v = v.superview) {
				if ([v isKindOfClass:[UIControl class]] && ((UIControl *)v).enabled) {
					[self ignoreTouch:t forEvent:event];
					break;
				}
			}
		}
	}
	((void (*)(id, SEL, NSSet *, UIEvent *))WATapTouchesBeganOriginal)(self, _cmd, touches, event);
}

#pragma mark - install

#pragma mark - WA4S additions (iOS 6 / iOS 5 APIs the 4S build uses)

// subscripting like arclite did
static id WAArrayAt(NSArray *a, SEL cmd, NSUInteger i) { return [a objectAtIndex:i]; }
static void WAArraySetAt(NSMutableArray *a, SEL cmd, id obj, NSUInteger i) {
	if (i == a.count) [a addObject:obj];
	else [a replaceObjectAtIndex:i withObject:obj];
}
static id WADictAt(NSDictionary *d, SEL cmd, id key) { return [d objectForKey:key]; }
static void WADictSetAt(NSMutableDictionary *d, SEL cmd, id obj, id key) {
	if (obj) [d setObject:obj forKey:key];
	else [d removeObjectForKey:key];
}

// ios 6 only, 3gs is scale 1 anyway
static UIImage *WAImageWithDataScale(id cls, SEL cmd, NSData *data, CGFloat scale) {
	UIImage *img = [UIImage imageWithData:data];
	if (!img || scale == 1) return img;
	return [UIImage imageWithCGImage:img.CGImage scale:scale orientation:img.imageOrientation];
}

// ios 6 only, use minimumFontSize
static void WASetMinimumScaleFactor(UILabel *self, SEL cmd, CGFloat factor) {
	self.minimumFontSize = self.font.pointSize * factor;
}

// ios 5 only, fake it with a clear toolbar
@interface WAClearToolbar : UIToolbar
@end
@implementation WAClearToolbar
- (void)drawRect:(CGRect)rect {}
@end

static void WASetRightBarButtonItems(UINavigationItem *self, SEL cmd, NSArray *items) {
	if (items.count <= 1) {
		self.rightBarButtonItem = items.lastObject;
		return;
	}
	WAClearToolbar *bar = [[WAClearToolbar alloc] initWithFrame:CGRectMake(0, 0, 44 * items.count + 12, 44)];
	bar.backgroundColor = [UIColor clearColor];
	bar.opaque = NO;
	bar.barStyle = UIBarStyleDefault;
	bar.items = [[items reverseObjectEnumerator] allObjects]; // first = rightmost
	self.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:bar];
}

static void WAInstallAdditions(void) {
	static char getIndexed[16], setIndexed[16];
	snprintf(getIndexed, sizeof getIndexed, "@@:%s", @encode(NSUInteger));
	snprintf(setIndexed, sizeof setIndexed, "v@:@%s", @encode(NSUInteger));
	class_addMethod([NSArray class], @selector(objectAtIndexedSubscript:), (IMP)WAArrayAt, getIndexed);
	class_addMethod([NSMutableArray class], @selector(setObject:atIndexedSubscript:), (IMP)WAArraySetAt, setIndexed);
	class_addMethod([NSDictionary class], @selector(objectForKeyedSubscript:), (IMP)WADictAt, "@@:@");
	class_addMethod([NSMutableDictionary class], @selector(setObject:forKeyedSubscript:), (IMP)WADictSetAt, "v@:@@");
	class_addMethod(object_getClass([UIImage class]), @selector(imageWithData:scale:), (IMP)WAImageWithDataScale, "@@:@f");
	class_addMethod([UILabel class], @selector(setMinimumScaleFactor:), (IMP)WASetMinimumScaleFactor, "v@:f");
	class_addMethod([UINavigationItem class], @selector(setRightBarButtonItems:), (IMP)WASetRightBarButtonItems, "v@:@");
}

void WACompat4Install(void) {
	static BOOL installed;
	if (installed) return;
	installed = YES;
	WAInstallAdditions(); // ios 6 bits, also needed on 5.1.1 (4s)
	if ([UIView respondsToSelector:@selector(appearance)]) return;

	Class viewMeta = object_getClass([UIView class]);
	class_addMethod(viewMeta, @selector(appearance), (IMP)WAAppearance, "@@:");
	class_addMethod(viewMeta, @selector(appearanceWhenContainedIn:), (IMP)WAAppearanceWhenContainedIn, "@@:#");
	Class barItemMeta = object_getClass([UIBarItem class]);
	class_addMethod(barItemMeta, @selector(appearance), (IMP)WAAppearance, "@@:");
	class_addMethod(barItemMeta, @selector(appearanceWhenContainedIn:), (IMP)WAAppearanceWhenContainedIn, "@@:#");

	WAAddSetters([UINavigationBar class], @[ @"setBackgroundImage:forBarMetrics:", @"setTitleTextAttributes:",
	                                          @"setShadowImage:", @"setTitleVerticalPositionAdjustment:forBarMetrics:" ]);
	WAAdd([UINavigationBar class], @"titleTextAttributes", (IMP)WANil, "@@:");
	WAAddSetters([UIBarButtonItem class], @[ @"setBackgroundImage:forState:barMetrics:", @"setBackgroundImage:forState:style:barMetrics:",
	                                          @"setBackButtonBackgroundImage:forState:barMetrics:", @"setTitleTextAttributes:forState:",
	                                          @"setTintColor:", @"setBackgroundVerticalPositionAdjustment:forBarMetrics:" ]);
	WAAddSetters([UITabBarItem class], @[ @"setTitleTextAttributes:forState:",
	                                       @"setTitlePositionAdjustment:" ]);
	WAAdd([UITabBarItem class], @"setFinishedSelectedImage:withFinishedUnselectedImage:", (IMP)WASetFinishedImages, "v@:@@");
	WAAddSetters([UITabBar class], @[ @"setBackgroundImage:", @"setSelectionIndicatorImage:", @"setTintColor:",
	                                   @"setSelectedImageTintColor:", @"setShadowImage:" ]);
	WAAddSetters([UIToolbar class], @[ @"setBackgroundImage:forToolbarPosition:barMetrics:", @"setShadowImage:forToolbarPosition:" ]);
	WAAddSetters([UISearchBar class], @[ @"setBackgroundImage:", @"setSearchFieldBackgroundImage:forState:",
	                                      @"setScopeBarBackgroundImage:", @"setImage:forSearchBarIcon:state:" ]);
	WAAddSetters([UISegmentedControl class], @[ @"setTitleTextAttributes:forState:", @"setBackgroundImage:forState:barMetrics:",
	                                             @"setDividerImage:forLeftSegmentState:rightSegmentState:barMetrics:" ]);
	WAAddSetters([UISwitch class], @[ @"setOnTintColor:", @"setTintColor:", @"setThumbTintColor:" ]);
	WAAddSetters([UISlider class], @[ @"setMinimumTrackTintColor:", @"setMaximumTrackTintColor:", @"setThumbTintColor:" ]);
	WAAddSetters([UIProgressView class], @[ @"setProgressTintColor:", @"setTrackTintColor:", @"setProgressImage:", @"setTrackImage:" ]);
	WAAddSetters([UIPageControl class], @[ @"setPageIndicatorTintColor:", @"setCurrentPageIndicatorTintColor:" ]);

	WAAdd([UIViewController class], @"presentViewController:animated:completion:", (IMP)WAPresent, "v@:@c@?");
	WAAdd([UIViewController class], @"dismissViewControllerAnimated:completion:", (IMP)WADismiss, "v@:c@?");
	WAAdd([UIViewController class], @"presentedViewController", (IMP)WAPresented, "@@:");
	WAAdd([UIViewController class], @"presentingViewController", (IMP)WAPresenting, "@@:");
	for (NSString *name in @[ @"isBeingPresented", @"isBeingDismissed", @"isMovingToParentViewController",
	                          @"isMovingFromParentViewController" ])
		WAAdd([UIViewController class], name, (IMP)WANo, "c@:");

	WAAdd([UIImage class], @"resizableImageWithCapInsets:", (IMP)WAResizable, "@@:{UIEdgeInsets=ffff}");
	class_addMethod(object_getClass([NSValue class]), @selector(valueWithUIOffset:), (IMP)WAValueWithUIOffset, "@@:{UIOffset=ff}");
	WAAdd([NSValue class], @"UIOffsetValue", (IMP)WAUIOffsetValue, "{UIOffset=ff}@:");
	WAAdd([UIColor class], @"getRed:green:blue:alpha:", (IMP)WAGetRGBA, "c@:^f^f^f^f");
	WAAdd([UIColor class], @"getWhite:alpha:", (IMP)WAGetWhite, "c@:^f^f");
	WAAdd([UITableView class], @"indexPathsForSelectedRows", (IMP)WASelectedRows, "@@:");
	WAAdd([UITableView class], @"moveRowAtIndexPath:toIndexPath:", (IMP)WAMoveRow, "v@:@@");
	WAAddSetters([UIActivityIndicatorView class], @[ @"setColor:" ]);
	if (![UIAlertView instancesRespondToSelector:@selector(textFieldAtIndex:)]) {
		WAAdd([UIAlertView class], @"alertViewStyle", (IMP)WAAlertStyle, "i@:");
		WAAdd([UIAlertView class], @"setAlertViewStyle:", (IMP)WASetAlertStyle, "v@:i");
		WAAdd([UIAlertView class], @"textFieldAtIndex:", (IMP)WATextFieldAtIndex, "@@:i");
		Method show = class_getInstanceMethod([UIAlertView class], @selector(show));
		WAAlertShowOriginal = method_setImplementation(show, (IMP)WAAlertShow);
	}
	WAAdd(objc_getClass("MPMediaItemArtwork"), @"initWithImage:", (IMP)WAArtworkInitWithImage, "@@:@");
	Method began = class_getInstanceMethod([UITapGestureRecognizer class], @selector(touchesBegan:withEvent:));
	WATapTouchesBeganOriginal = method_getImplementation(began);
	if (!class_addMethod([UITapGestureRecognizer class], @selector(touchesBegan:withEvent:), (IMP)WATapTouchesBegan,
	                     method_getTypeEncoding(began)))
		method_setImplementation(began, (IMP)WATapTouchesBegan);
	Class conn = objc_getClass("NSURLConnection");
	if (conn && ![conn respondsToSelector:@selector(sendAsynchronousRequest:queue:completionHandler:)])
		class_addMethod(object_getClass(conn), @selector(sendAsynchronousRequest:queue:completionHandler:), (IMP)WASendAsync, "v@:@@@?");

	NSLog(@"[WA4S iOS4] iOS 5 compatibility installed");
}
#endif
