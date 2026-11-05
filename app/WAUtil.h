#import <UIKit/UIKit.h>

NSString *WAShortTime(long long ts); // chat list
NSString *WAClockTime(long long ts); // bubble
NSString *WALastSeen(long long ts); // last seen
NSString *WAFutureTime(long long ts);
NSString *WAKindLabel(NSString *kind);
// strip FE0F + skin tones, old ios shows boxes
NSString *WAEmojiForDisplay(NSString *emoji);
NSString *WACallText(NSDictionary *m); // call line text
UIColor *WAColor(unsigned rgb);
UIColor *WANameColor(NSString *jid);

// log.txt, capped ~200kb
void WALog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
