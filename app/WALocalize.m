#import "WALocalize.h"

// also built into the springboard tweak without arc: statics only hold alloc/init'ed objects
#if __has_feature(objc_arc)
#define WARelease(x)
#define WAAutorelease(x) (x)
#define WAKeep(x) (x)
#else
#define WARelease(x) [x release]
#define WAAutorelease(x) [x autorelease]
#define WAKeep(x) [[x retain] autorelease]
#endif

static NSString *const kAssetDir = @"/var/mobile/Library/WA4S/Assets";

// languages whatsapp 2.10.2 ships
static NSArray *WALanguages(void) {
	static NSArray *langs;
	if (!langs) langs = [[NSArray alloc] initWithObjects:@"ar", @"ca", @"cs", @"da", @"de", @"el", @"en-GB", @"en", @"es", @"fi",
		@"fr", @"he", @"hr", @"hu", @"id", @"it", @"ja", @"ko", @"ms", @"nb", @"nl", @"pl", @"pt-PT", @"pt", @"ro", @"ru", @"sk",
		@"sv", @"th", @"tr", @"uk", @"vi", @"zh-Hans", @"zh-Hant", nil];
	return langs;
}

// "de-AT" -> de-AT, de. "zh-Hans-CN" -> zh-Hans-CN, zh-Hans, zh
static NSArray *Candidates(NSString *pref) {
	NSMutableArray *out = [NSMutableArray array];
	NSString *s = [pref stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
	while (s.length) {
		[out addObject:s];
		NSRange dash = [s rangeOfString:@"-" options:NSBackwardsSearch];
		s = dash.location == NSNotFound ? nil : [s substringToIndex:dash.location];
	}
	return out;
}

// user defaults first: the app's own AppleLanguages (if set) wins over the system one, like NSBundle does
#define kLanguageChanged CFSTR("com.aronsz26.wa4s.language")
static NSString *const kAppPrefs = @"/var/mobile/Library/Preferences/com.aronsz26.wa4s.plist";

static BOOL InApp(void) {
	return [[[NSBundle mainBundle] bundleIdentifier] hasPrefix:@"com.aronsz26.wa4s"];
}

// the language picked in the app, read from its prefs file when we're the tweak in springboard
static NSArray *AppLanguages(void) {
	if (InApp()) return [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.aronsz26.wa4s"][@"AppleLanguages"];
	NSDictionary *d = [[NSDictionary alloc] initWithContentsOfFile:kAppPrefs];
	NSArray *langs = WAKeep([d objectForKey:@"AppleLanguages"]);
	WARelease(d);
	return langs;
}

// languages with our own texts on top of whatsapp's, everything else is english
static NSArray *FullLanguages(void) {
	static NSArray *langs;
	if (!langs) langs = [[NSArray alloc] initWithObjects:@"en", @"de", @"es", @"fr", @"id", @"it", @"nl", @"pt", nil];
	return langs;
}

static NSString *RequestedLanguage(void);

// "de-AT" stays, "cs" becomes "en"
static NSString *PreferredLanguage(void) {
	NSString *lang = RequestedLanguage();
	return [FullLanguages() containsObject:[Candidates(lang) lastObject]] ? lang : @"en";
}

static NSString *RequestedLanguage(void) {
	NSArray *chosen = AppLanguages();
	if ([chosen isKindOfClass:[NSArray class]] && [[chosen lastObject] isKindOfClass:[NSString class]]) return [chosen objectAtIndex:0];
	NSArray *prefs = InApp() ? [[NSUserDefaults standardUserDefaults] arrayForKey:@"AppleLanguages"] : nil;
	if (![[prefs lastObject] isKindOfClass:[NSString class]]) prefs = [NSLocale preferredLanguages];
	return prefs.count ? [prefs objectAtIndex:0] : @"en";
}

NSString *WALanguageDir(void) {
	NSArray *langs = WALanguages();
	for (NSString *c in Candidates(PreferredLanguage())) {
		if ([langs containsObject:c]) return c;
	}
	return @"en";
}

// "it" + the iPhone's region -> it_IT, "de-AT" stays de_AT
static NSLocale *gDateLocale;
static NSUInteger gGeneration;

static NSLocale *DateLocale(void) {
	NSLocale *locale = gDateLocale;
	if (locale) return locale;
	NSString *lang = [[Candidates(PreferredLanguage()) objectAtIndex:0] stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
	NSString *country = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
	BOOL hasRegion = [lang rangeOfString:@"_"].location != NSNotFound && ![lang hasPrefix:@"zh_"];
	NSString *ident = hasRegion || !country.length ? lang : [lang stringByAppendingFormat:@"_%@", country];
	gDateLocale = [[NSLocale alloc] initWithLocaleIdentifier:ident];
	return gDateLocale;
}

NSDateFormatter *WADateFormatter(NSString *englishFormat, NSString *dateTemplate) {
	NSDateFormatter *f = [[NSDateFormatter alloc] init];
	BOOL english = [[Candidates(PreferredLanguage()) lastObject] isEqualToString:@"en"];
	NSLocale *locale = english ? nil : DateLocale();
	NSString *format = locale ? [NSDateFormatter dateFormatFromTemplate:dateTemplate options:0 locale:locale] : nil;
	if (format.length) {
		f.locale = locale;
		f.dateFormat = format;
	} else {
		NSLocale *gb = [[NSLocale alloc] initWithLocaleIdentifier:@"en_GB"];
		f.locale = gb;
		WARelease(gb);
		f.dateFormat = englishFormat;
	}
	return WAAutorelease(f);
}

NSString *WACapitalized(NSString *s) {
	if (s.length < 2) return [s uppercaseString];
	return [[[s substringToIndex:1] uppercaseString] stringByAppendingString:[s substringFromIndex:1]];
}

// the app itself or the tweak in springboard
static NSString *AppPath(void) {
	NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
	return [bundle hasPrefix:@"com.aronsz26.wa4s"] ? [[NSBundle mainBundle] bundlePath] : @"/Applications/WA4S.app";
}

static NSDictionary *gOwn, *gWhatsApp, *gEnglishKeys;
static BOOL gEnglish, gLoaded;

static void LanguageChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef info) {
	WALReload();
}

static void Load(void) {
	gLoaded = YES;
	static BOOL listening;
	if (!listening && !InApp()) {
		listening = YES;
		CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, LanguageChanged,
			kLanguageChanged, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	}
	NSArray *candidates = Candidates(PreferredLanguage());
	gEnglish = [[candidates lastObject] isEqualToString:@"en"];
	if (gEnglish) return;
	NSString *app = AppPath();
	for (NSString *c in candidates) {
		NSString *path = [app stringByAppendingFormat:@"/%@.lproj/WAClassic.strings", c];
		NSDictionary *d = [[NSDictionary alloc] initWithContentsOfFile:path];
		if (d.count) {
			gOwn = d;
			break;
		}
		WARelease(d);
	}
	NSString *dir = WALanguageDir();
	if ([dir isEqualToString:@"en"]) return;
	NSDictionary *en = [[NSDictionary alloc] initWithContentsOfFile:[kAssetDir stringByAppendingString:@"/en.lproj/Localizable.strings"]];
	NSDictionary *target = [[NSDictionary alloc] initWithContentsOfFile:
		[kAssetDir stringByAppendingFormat:@"/%@.lproj/Localizable.strings", dir]];
	if (en.count && target.count) {
		// whatsapp's keys aren't the english text, so english text -> key
		NSMutableDictionary *keys = [[NSMutableDictionary alloc] initWithCapacity:en.count];
		for (NSString *key in en) {
			NSString *text = [en objectForKey:key];
			if ([text isKindOfClass:[NSString class]] && ![keys objectForKey:text]) [keys setObject:key forKey:text];
		}
		gEnglishKeys = keys;
		gWhatsApp = target;
		target = nil;
	}
	WARelease(en);
	WARelease(target);
}

NSUInteger WALanguageGeneration(void) {
	return gGeneration;
}

NSArray *WASupportedLanguages(void) {
	return FullLanguages();
}

// "italiano" -> "Italiano", "pt-PT" -> "Português (Portugal)"
NSString *WALanguageName(NSString *code) {
	NSString *ident = [code stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
	NSLocale *own = [[NSLocale alloc] initWithLocaleIdentifier:ident];
	NSString *name = [own displayNameForKey:NSLocaleIdentifier value:ident];
	WARelease(own);
	return name.length ? WACapitalized(name) : code;
}

NSString *WAChosenLanguage(void) {
	NSArray *chosen = AppLanguages();
	NSString *code = [chosen isKindOfClass:[NSArray class]] && chosen.count ? [chosen objectAtIndex:0] : nil;
	return [FullLanguages() containsObject:code] ? code : nil; // picked before the list got shorter: shows as automatic
}

void WASetLanguage(NSString *code) {
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	if (code) [d setObject:[NSArray arrayWithObject:code] forKey:@"AppleLanguages"];
	else [d removeObjectForKey:@"AppleLanguages"];
	[d synchronize];
	WALReload();
	CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), kLanguageChanged, NULL, NULL, YES);
}

void WALReload(void) {
	WARelease(gDateLocale);
	gDateLocale = nil;
	gGeneration++;
	WARelease(gOwn);
	WARelease(gWhatsApp);
	WARelease(gEnglishKeys);
	gOwn = gWhatsApp = gEnglishKeys = nil;
	gLoaded = NO;
}

// "%lu items" -> [lu]. a translation with other placeholders would crash stringWithFormat
static NSArray *Placeholders(NSString *s) {
	if ([s rangeOfString:@"%"].location == NSNotFound) return nil;
	static NSRegularExpression *re;
	if (!re) re = [[NSRegularExpression alloc] initWithPattern:@"%(?:\\d+\\$)?[-+ 0#]*\\d*(?:\\.\\d+)?(hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfeEgGcCsSp%])"
		options:0 error:NULL];
	NSMutableArray *out = [NSMutableArray array];
	for (NSTextCheckingResult *m in [re matchesInString:s options:0 range:NSMakeRange(0, s.length)]) {
		NSString *type = [s substringWithRange:[m rangeAtIndex:2]];
		if ([type isEqualToString:@"%"]) continue;
		NSRange len = [m rangeAtIndex:1];
		[out addObject:[(len.location == NSNotFound ? @"" : [s substringWithRange:len]) stringByAppendingString:type]];
	}
	return [out sortedArrayUsingSelector:@selector(compare:)];
}

static BOOL Fits(NSString *english, NSString *text) {
	if (![text isKindOfClass:[NSString class]] || !text.length) return NO;
	NSArray *a = Placeholders(english), *b = Placeholders(text);
	return a == b || [a isEqualToArray:b] || (!a.count && !b.count);
}

NSString *WAL(NSString *english) {
	if (!english) return nil;
	if (!gLoaded) Load();
	if (gEnglish) return english;
	NSString *own = [gOwn objectForKey:english];
	if (Fits(english, own)) return own;
	NSString *key = [gEnglishKeys objectForKey:english];
	NSString *theirs = key ? [gWhatsApp objectForKey:key] : nil;
	if (Fits(english, theirs)) return theirs;
	return english;
}
