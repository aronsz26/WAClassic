// prefix header for the ios 4 build
// ios 5/6 string constants are NULL on ios 4 (weak import), reading them crashes.
// redefine them as their literal values
#ifdef WA_IOS4
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

#define AVAudioSessionModeVoiceChat @"AVAudioSessionModeVoiceChat"
#endif
#endif
