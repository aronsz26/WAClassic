// WAIOS4Runtime - ARC runtime functions for ios 4 (3gs)
// built without -fobjc-arc, ios 4 build only. ios 4's libobjc has no objc_retain etc
// and no weak refs at all, libarclite never had weak and isn't shipped anymore.
// these live in our binary so only our own code uses them.
// weak refs: table object -> addresses, patched -[NSObject dealloc] zeroes them.
// doesn't work for NSProxy / toll-free CF objects, and isn't thread safe vs dealloc
// (we only use weak on the main thread)

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <Block.h>
#include <pthread.h>

#pragma mark - strong references (libarclite's set)

id objc_retain(id obj) {
	return obj ? [obj retain] : nil;
}

void objc_release(id obj) {
	if (obj) [obj release];
}

id objc_autorelease(id obj) {
	return obj ? [obj autorelease] : nil;
}

id objc_retainAutorelease(id obj) {
	return obj ? [[obj retain] autorelease] : nil;
}

id objc_autoreleaseReturnValue(id obj) {
	return objc_autorelease(obj);
}

id objc_retainAutoreleaseReturnValue(id obj) {
	return objc_retainAutorelease(obj);
}

id objc_retainAutoreleasedReturnValue(id obj) {
	return objc_retain(obj);
}

id objc_retainBlock(id block) {
	return block ? (id)_Block_copy((const void *)block) : nil;
}

void objc_storeStrong(id *location, id obj) {
	id old = *location;
	if (old == obj) return;
	*location = obj ? [obj retain] : nil;
	if (old) [old release];
}

void *objc_autoreleasePoolPush(void) {
	return [[NSAutoreleasePool alloc] init];
}

void objc_autoreleasePoolPop(void *pool) {
	[(NSAutoreleasePool *)pool drain];
}

#pragma mark - zeroing weak references

static pthread_mutex_t WAWeakLock = PTHREAD_MUTEX_INITIALIZER;
static CFMutableDictionaryRef WAWeakTable; // object -> set of id* (nothing retained)
static IMP WAOriginalDealloc;

static void WAWeakRemoveLocation(id obj, id *location) {
	if (!obj || !WAWeakTable) return;
	CFMutableSetRef set = (CFMutableSetRef)CFDictionaryGetValue(WAWeakTable, obj);
	if (!set) return;
	CFSetRemoveValue(set, location);
	if (CFSetGetCount(set) == 0) CFDictionaryRemoveValue(WAWeakTable, obj);
}

static void WAWeakAddLocation(id obj, id *location) {
	if (!WAWeakTable) WAWeakTable = CFDictionaryCreateMutable(NULL, 0, NULL, &kCFTypeDictionaryValueCallBacks);
	CFMutableSetRef set = (CFMutableSetRef)CFDictionaryGetValue(WAWeakTable, obj);
	if (!set) {
		set = CFSetCreateMutable(NULL, 0, NULL);
		CFDictionarySetValue(WAWeakTable, obj, set);
		CFRelease(set);
	}
	CFSetAddValue(set, location);
}

static void WAWeakClearLocation(const void *value, void *context) {
	id *location = (id *)value;
	if (*location == (id)context) *location = nil;
}

// zero weak refs, then original dealloc
static void WAWeakDealloc(id self, SEL _cmd) {
	pthread_mutex_lock(&WAWeakLock);
	if (WAWeakTable) {
		CFMutableSetRef set = (CFMutableSetRef)CFDictionaryGetValue(WAWeakTable, self);
		if (set) {
			CFSetApplyFunction(set, WAWeakClearLocation, self);
			CFDictionaryRemoveValue(WAWeakTable, self);
		}
	}
	pthread_mutex_unlock(&WAWeakLock);
	((void (*)(id, SEL))WAOriginalDealloc)(self, _cmd);
}

id objc_storeWeak(id *location, id obj) {
	pthread_mutex_lock(&WAWeakLock);
	id old = *location;
	if (old != obj) {
		WAWeakRemoveLocation(old, location);
		*location = obj;
		if (obj) WAWeakAddLocation(obj, location);
	}
	pthread_mutex_unlock(&WAWeakLock);
	return obj;
}

id objc_initWeak(id *location, id obj) {
	*location = nil;
	return objc_storeWeak(location, obj);
}

void objc_destroyWeak(id *location) {
	objc_storeWeak(location, nil);
}

id objc_loadWeakRetained(id *location) {
	pthread_mutex_lock(&WAWeakLock);
	id obj = *location;
	if (obj) [obj retain];
	pthread_mutex_unlock(&WAWeakLock);
	return obj;
}

id objc_loadWeak(id *location) {
	return [objc_loadWeakRetained(location) autorelease];
}

void objc_copyWeak(id *to, id *from) {
	id obj = objc_loadWeakRetained(from);
	objc_initWeak(to, obj);
	if (obj) [obj release];
}

void objc_moveWeak(id *to, id *from) {
	objc_copyWeak(to, from);
	objc_destroyWeak(from);
}

#pragma mark - install

// call first in main()
void WAIOS4RuntimeInstall(void) {
	static BOOL installed;
	if (installed) return;
	installed = YES;
	Method dealloc = class_getInstanceMethod([NSObject class], sel_registerName("dealloc"));
	WAOriginalDealloc = method_setImplementation(dealloc, (IMP)WAWeakDealloc);
	NSLog(@"[WA4S] iOS 4 runtime: ARC entry points and zeroing weak references active");
}
