#import <UIKit/UIKit.h>

// recolored 2.10 bubbles (gloss kept). Green/White = originals
NSArray *WABubbleColorNames(void);
UIColor *WABubbleFill(NSString *name, BOOL mine); // fallback
UIImage *WABubbleImage(NSString *name, BOOL mine);
void WABubblesReset(void);
UIImage *WABubbleSwatch(NSString *name, BOOL mine); // for settings
