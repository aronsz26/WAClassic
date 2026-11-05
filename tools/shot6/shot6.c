// shot6 - command line screenshot for ios 6 (root, over ssh)
// renders the display into an IOSurface via CARenderServerRenderDisplay
// usage: shot6 /tmp/screen.png [w h]  (default 640x960)
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>

typedef void *IOSurfaceRef;

#define LOAD(lib, name) name##_f = dlsym(lib, #name); if (!name##_f) { fprintf(stderr, "missing %s\n", #name); return 1; }

int main(int argc, char **argv) {
	const char *out = argc > 1 ? argv[1] : "/tmp/screen.png";
	void *surf = dlopen("/System/Library/PrivateFrameworks/IOSurface.framework/IOSurface", RTLD_NOW);
	if (!surf) { fprintf(stderr, "dlopen failed\n"); return 1; }

	int (*IOSurfaceLock_f)(IOSurfaceRef, uint32_t, uint32_t *);
	int (*IOSurfaceUnlock_f)(IOSurfaceRef, uint32_t, uint32_t *);
	void *(*IOSurfaceGetBaseAddress_f)(IOSurfaceRef);
	LOAD(surf, IOSurfaceLock) LOAD(surf, IOSurfaceUnlock) LOAD(surf, IOSurfaceGetBaseAddress)

	// render into our own linear surface, the framebuffer is tiled
	IOSurfaceRef (*IOSurfaceCreate_f)(CFDictionaryRef);
	void (*CARenderServerRenderDisplay_f)(kern_return_t, CFStringRef, IOSurfaceRef, int, int);
	void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
	LOAD(surf, IOSurfaceCreate) LOAD(qc, CARenderServerRenderDisplay)
	int w = 640, h = 960;
	if (argc > 3) { w = atoi(argv[2]); h = atoi(argv[3]); }
	int bpe = 4, bpr = w * bpe, size = bpr * h;
	unsigned fmt = 'BGRA';
	CFMutableDictionaryRef props = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	const char *keys[] = {"IOSurfaceIsGlobal", "IOSurfaceBytesPerElement", "IOSurfaceBytesPerRow", "IOSurfaceWidth", "IOSurfaceHeight", "IOSurfacePixelFormat", "IOSurfaceAllocSize"};
	int vals[] = {1, bpe, bpr, w, h, (int)fmt, size};
	for (int i = 0; i < 7; i++) {
		CFStringRef k = CFStringCreateWithCString(NULL, keys[i], kCFStringEncodingUTF8);
		if (i == 0) { CFDictionarySetValue(props, k, kCFBooleanTrue); continue; }
		CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &vals[i]);
		CFDictionarySetValue(props, k, n);
	}
	IOSurfaceRef s = IOSurfaceCreate_f(props);
	if (!s) { fprintf(stderr, "IOSurfaceCreate failed\n"); return 1; }
	CARenderServerRenderDisplay_f(0, CFSTR("LCD"), s, 0, 0);
	IOSurfaceLock_f(s, 1, NULL);
	CFDataRef pixels = CFDataCreate(NULL, IOSurfaceGetBaseAddress_f(s), bpr * h);
	IOSurfaceUnlock_f(s, 1, NULL);
	CGDataProviderRef provider = CGDataProviderCreateWithCFData(pixels);
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGImageRef img = CGImageCreate(w, h, 8, 32, bpr, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
		provider, NULL, false, kCGRenderingIntentDefault);
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)out, strlen(out), false);
	CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
	CGImageDestinationAddImage(dest, img, NULL);
	bool ok = CGImageDestinationFinalize(dest);
	printf("%dx%d %s\n", w, h, ok ? out : "write failed");
	return ok ? 0 : 1;
}
