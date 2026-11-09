#import <Foundation/Foundation.h>

// TLSFix (Skyglow) swaps the system tls for openssl in every app and checks certificates with
// SecTrustEvaluate against the normal roots, ignoring "don't validate the chain". our bridge is
// self-signed and pinned, so away from home broke ("unknown certificate", under tls 1.3 "bad record MAC").
// tlsfix looks SecTrustEvaluate up with dlsym, so in its image only we answer that lookup (and any
// pointer it already keeps) with a check that lets our pinned bridge through. everything else is
// checked like before, other images and other apps aren't touched.
void WATLSFixStart(void); // in main, before any tls
BOOL WATLSFixActive(void); // tlsfix is loaded: uploads go in pieces, its openssl breaks big writes
