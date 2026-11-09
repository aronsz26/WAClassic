#import "WATLSFix.h"
#import <Security/Security.h>
#import "WAClient.h"
#import "WAUtil.h"
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#ifdef __LP64__
typedef struct mach_header_64 WAHeader;
typedef struct segment_command_64 WASegment;
typedef struct section_64 WASection;
typedef struct nlist_64 WANlist;
#define WA_SEGMENT LC_SEGMENT_64
#else
typedef struct mach_header WAHeader;
typedef struct segment_command WASegment;
typedef struct section WASection;
typedef struct nlist WANlist;
#define WA_SEGMENT LC_SEGMENT
#endif

// own compare, the ios 4 link has no strcmp stub
static int Same(const char *a, const char *b) {
	while (*a && *a == *b) a++, b++;
	return *a == *b;
}

static BOOL active;
BOOL WATLSFixActive(void) { return active; }

static OSStatus (*realEvaluate)(SecTrustRef, SecTrustResultType *);
static void *(*realDlsym)(void *, const char *);

static OSStatus PinnedEvaluate(SecTrustRef trust, SecTrustResultType *result) {
	OSStatus err = realEvaluate(trust, result);
	if (err == noErr && result && *result != kSecTrustResultProceed && *result != kSecTrustResultUnspecified) {
		NSString *pin = [WAClient shared].pin;
		if (pin.length && WAPinMatches(trust, pin)) *result = kSecTrustResultProceed;
	}
	return err;
}

static void *TLSFixDlsym(void *handle, const char *name) {
	if (name && Same(name, "SecTrustEvaluate")) return (void *)PinnedEvaluate;
	return realDlsym(handle, name);
}

// in one image: import pointers named `symbol` -> replacement, and data words equal to `old` -> replacement
static int Patch(const WAHeader *header, intptr_t slide, const char *symbol, void *replacement, void *old, void *oldReplacement) {
	WASegment *linkedit = NULL;
	struct symtab_command *symtab = NULL;
	struct dysymtab_command *dysymtab = NULL;
	uintptr_t cur = (uintptr_t)header + sizeof(WAHeader);
	for (uint32_t i = 0; i < header->ncmds; i++, cur += ((struct load_command *)cur)->cmdsize) {
		struct load_command *lc = (struct load_command *)cur;
		if (lc->cmd == WA_SEGMENT && Same(((WASegment *)lc)->segname, SEG_LINKEDIT)) linkedit = (WASegment *)lc;
		else if (lc->cmd == LC_SYMTAB) symtab = (struct symtab_command *)lc;
		else if (lc->cmd == LC_DYSYMTAB) dysymtab = (struct dysymtab_command *)lc;
	}
	if (!linkedit || !symtab || !dysymtab) return 0;
	uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
	WANlist *syms = (WANlist *)(base + symtab->symoff);
	char *strs = (char *)(base + symtab->stroff);
	uint32_t *indirect = (uint32_t *)(base + dysymtab->indirectsymoff);
	int done = 0;
	cur = (uintptr_t)header + sizeof(WAHeader);
	for (uint32_t i = 0; i < header->ncmds; i++, cur += ((struct load_command *)cur)->cmdsize) {
		struct load_command *lc = (struct load_command *)cur;
		if (lc->cmd != WA_SEGMENT || !Same(((WASegment *)lc)->segname, SEG_DATA)) continue;
		WASegment *seg = (WASegment *)lc;
		WASection *sect = (WASection *)(cur + sizeof(WASegment));
		for (uint32_t j = 0; j < seg->nsects; j++, sect++) {
			void **ptrs = (void **)((uintptr_t)slide + sect->addr);
			uint32_t count = (uint32_t)(sect->size / sizeof(void *));
			uint32_t type = sect->flags & SECTION_TYPE;
			if (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS) {
				uint32_t *idx = indirect + sect->reserved1;
				for (uint32_t k = 0; k < count; k++) {
					uint32_t s = idx[k];
					if (s & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL)) continue;
					if (!Same(strs + syms[s].n_un.n_strx, symbol)) continue;
					ptrs[k] = replacement;
					done++;
				}
			} else if (type == S_REGULAR || type == S_ZEROFILL) {
				// SecTrustEvaluate already looked up and kept somewhere
				for (uint32_t k = 0; k < count; k++) {
					if (ptrs[k] != old) continue;
					ptrs[k] = oldReplacement;
					done++;
				}
			}
		}
	}
	return done;
}

void WATLSFixStart(void) {
	realEvaluate = SecTrustEvaluate;
	realDlsym = dlsym;
	void *evaluate = dlsym(RTLD_DEFAULT, "SecTrustEvaluate");
	for (uint32_t i = 0; i < _dyld_image_count(); i++) {
		const char *name = _dyld_get_image_name(i);
		if (!name || !strstr(name, "/tlsfix.dylib")) continue;
		active = YES;
		int n = Patch((const WAHeader *)_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i), "_dlsym",
			(void *)TLSFixDlsym, evaluate, (void *)PinnedEvaluate);
		WALog(@"tlsfix: %d place%s pointed at the pin check", n, n == 1 ? "" : "s");
	}
}
