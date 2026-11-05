#import <UIKit/UIKit.h>

// app settings in NSUserDefaults, 2.10 defaults
extern NSString *const WAPrefMessageAlerts, *const WAPrefMessageSound;
extern NSString *const WAPrefGroupAlerts, *const WAPrefGroupSound;
extern NSString *const WAPrefShowPreview;
extern NSString *const WAPrefInAppSounds, *const WAPrefInAppVibrate, *const WAPrefInAppPreview;
extern NSString *const WAPrefMessageTimestamp, *const WAPrefSaveIncomingMedia, *const WAPrefAutoDownload;
extern NSString *const WAPrefWallpaper; // nil = default
// auto-download: never / wifi / all
extern NSString *const WAPrefAutoPhotos, *const WAPrefAutoAudio, *const WAPrefAutoVideos;
extern NSString *const WAPrefOptimizeVideo; // off / cellular / always
extern NSString *const WAPrefBubbleOut, *const WAPrefBubbleIn;
// video calls hidden for 1.0, debug switch "videoCalls" (not in settings)
extern NSString *const WAPrefVideoCalls;
extern NSString *const WAPrefsChangedNotification;

BOOL WAPrefBool(NSString *key);
void WASetPref(NSString *key, id value);
NSString *WAPrefString(NSString *key);

BOOL WAOnWiFi(void);
BOOL WAAutoDownload(NSString *key);
BOOL WAOptimizeVideoNow(void);
BOOL WAVideoCallsEnabled(void);

// per chat bubble color or default
NSString *WABubbleColorName(NSString *jid, BOOL mine);
NSString *WAChatBubble(NSString *jid, BOOL mine);
void WASetChatBubble(NSString *jid, BOOL mine, NSString *name);

// 2.10 alert sounds
NSArray *WASoundNames(void);
NSString *WASoundFile(NSString *name);
void WAPlaySound(NSString *name);
