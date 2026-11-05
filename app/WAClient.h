#import <UIKit/UIKit.h>
#import <Security/Security.h>

// every long poll answer, main thread
// userInfo: messages, chatsChanged, presence, call
extern NSString *const WAClientUpdatesNotification;
// switched between home/away
extern NSString *const WAClientServerChangedNotification;
// network changed
extern NSString *const WAClientNetworkChangedNotification;

typedef void (^WAJSONBlock)(id json, NSError *error);

// bridge client, http + json, key in X-WA4S-Token
@interface WAClient : NSObject

+ (WAClient *)shared;

// home: plain http in the lan, away: https via router with pinned cert (sha256)
@property (nonatomic, copy) NSString *homeURL, *awayURL, *pin;
@property (nonatomic, copy) NSString *token;
@property (nonatomic, readonly) NSString *serverURL;
@property (nonatomic, readonly) BOOL away;
// pick the address that works
- (void)chooseServer:(void (^)(BOOL reachable))done;
// main thread only
- (void)load:(NSURLRequest *)request completion:(void (^)(NSData *data, NSInteger status, NSError *error))completion;
@property (nonatomic, readonly) BOOL configured;
@property (nonatomic, copy) NSString *ownJID;
@property (nonatomic, readonly) long long upd;
- (void)noteUpd:(long long)upd;

- (void)saveSettings;
// setup code -> key, away address, pin. port defaults to 8097
- (void)setupWithAddress:(NSString *)address code:(NSString *)code completion:(void (^)(NSError *error))completion;

// raw response (images etc)
- (NSMutableURLRequest *)requestFor:(NSString *)path params:(NSDictionary *)params;
- (void)get:(NSString *)path params:(NSDictionary *)params completion:(WAJSONBlock)completion;
- (void)post:(NSString *)path params:(NSDictionary *)params completion:(WAJSONBlock)completion;
- (void)post:(NSString *)path params:(NSDictionary *)params data:(NSData *)body contentType:(NSString *)type
	completion:(WAJSONBlock)completion;
- (NSURLRequest *)mediaRequestForSeq:(long long)seq;
- (NSURLRequest *)mediaRequestForSeq:(long long)seq format:(NSString *)format; // mp4 / poster / m4a
- (NSURLRequest *)voiceRequestForSeq:(long long)seq;
- (NSURLRequest *)videoRequestForSeq:(long long)seq optimized:(BOOL)small; // small = optimize video

// avatars, cached
- (UIImage *)cachedAvatarFor:(NSString *)jid;
- (void)avatarFor:(NSString *)jid completion:(void (^)(UIImage *image))completion;
- (NSURLRequest *)fullAvatarRequestFor:(NSString *)jid;

// set online (whatsapp only sends presence while we're online)
- (void)setOnline:(BOOL)online;

// long poll after upd
- (void)startUpdatesFrom:(long long)upd;
- (void)stopUpdates;

@end

NSString *WAEscape(NSString *s);
BOOL WAPinMatches(SecTrustRef trust, NSString *pin);
