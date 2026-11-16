#import <Foundation/Foundation.h>

// texts in the iPhone's language. the english text is the key:
// 1. our own WAClassic.strings in the app (de, es, fr, id, it, nl, pt)
// 2. whatsapp 2.10's own Localizable.strings, synced from the bridge like the graphics (34 languages)
// 3. english
NSString *WAL(NSString *english);

// whatsapp's .lproj folder for this iPhone, "en" if it has none
NSString *WALanguageDir(void);

// dates in the app's language. english keeps the 2.10 formats (en_GB, 24 h, dd/MM/yy),
// other languages get the template in their own order, e.g. "ddMMyy" -> dd.MM.yy in german
NSDateFormatter *WADateFormatter(NSString *englishFormat, NSString *dateTemplate);
// "lunedì" -> "Lunedì" for labels that start with the date
NSString *WACapitalized(NSString *s);

// languages to pick in Settings › Languages (whatsapp 2.10's 34), name in that language
NSArray *WASupportedLanguages(void);
NSString *WALanguageName(NSString *code);
// picked language, nil = the iPhone's
NSString *WAChosenLanguage(void);
// saves it, reloads texts and dates, tells the springboard tweak. nil = back to the iPhone's
void WASetLanguage(NSString *code);
// goes up on every switch, caches of translated things compare it
NSUInteger WALanguageGeneration(void);

// after new strings arrived from the bridge
void WALReload(void);
