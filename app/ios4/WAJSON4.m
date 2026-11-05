// WAJSON4 - minimal NSJSONSerialization for ios 4 (flat namespace picks it up).
// only what we use, no pretty printing
#ifdef WA_IOS4
#import <Foundation/Foundation.h>
#include <stdlib.h>

@implementation NSJSONSerialization

#pragma mark reading

typedef struct {
	const unsigned char *p, *end;
	NSJSONReadingOptions options;
	NSString *problem;
} WAJSONReader;

static void WASkipSpace(WAJSONReader *r) {
	while (r->p < r->end && (*r->p == ' ' || *r->p == '\t' || *r->p == '\n' || *r->p == '\r')) r->p++;
}

static id WAReadValue(WAJSONReader *r, int depth);

static int WAHex(unsigned char c) {
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

static BOOL WARead4Hex(WAJSONReader *r, unichar *out) {
	if (r->end - r->p < 4) return NO;
	unichar v = 0;
	for (int i = 0; i < 4; i++) {
		int h = WAHex(r->p[i]);
		if (h < 0) return NO;
		v = (unichar)(v * 16 + h);
	}
	r->p += 4;
	*out = v;
	return YES;
}

static NSString *WAReadString(WAJSONReader *r) {
	r->p++;
	NSMutableString *s = nil;
	const unsigned char *run = r->p;
	while (r->p < r->end) {
		unsigned char c = *r->p;
		if (c == '"' || c == '\\') {
			if (r->p > run) {
				NSString *part = [[NSString alloc] initWithBytes:run length:(NSUInteger)(r->p - run) encoding:NSUTF8StringEncoding];
				if (!part) { r->problem = @"invalid UTF-8"; return nil; }
				if (!s) s = [NSMutableString stringWithCapacity:part.length + 8];
				[s appendString:part];
			}
			if (!s) s = [NSMutableString string];
			if (c == '"') {
				r->p++;
				return s;
			}
			r->p++;
			if (r->p >= r->end) break;
			unsigned char e = *r->p++;
			unichar u;
			switch (e) {
				case '"': u = '"'; break;
				case '\\': u = '\\'; break;
				case '/': u = '/'; break;
				case 'b': u = '\b'; break;
				case 'f': u = '\f'; break;
				case 'n': u = '\n'; break;
				case 'r': u = '\r'; break;
				case 't': u = '\t'; break;
				case 'u':
					if (!WARead4Hex(r, &u)) { r->problem = @"bad \\u escape"; return nil; }
					if (u >= 0xD800 && u <= 0xDBFF && r->end - r->p >= 6 && r->p[0] == '\\' && r->p[1] == 'u') {
						unichar lo;
						r->p += 2;
						if (WARead4Hex(r, &lo) && lo >= 0xDC00 && lo <= 0xDFFF) {
							unichar pair[2] = { u, lo };
							[s appendString:[NSString stringWithCharacters:pair length:2]];
							run = r->p;
							continue;
						}
						r->problem = @"bad surrogate pair";
						return nil;
					}
					break;
				default:
					r->problem = @"bad escape";
					return nil;
			}
			[s appendString:[NSString stringWithCharacters:&u length:1]];
			run = r->p;
			continue;
		}
		r->p++;
	}
	r->problem = @"unterminated string";
	return nil;
}

static id WAReadNumber(WAJSONReader *r) {
	const unsigned char *start = r->p;
	BOOL fraction = NO;
	if (r->p < r->end && *r->p == '-') r->p++;
	while (r->p < r->end) {
		unsigned char c = *r->p;
		if (c >= '0' && c <= '9') r->p++;
		else if (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') { fraction = YES; r->p++; }
		else break;
	}
	char buf[64];
	size_t len = (size_t)(r->p - start);
	if (len == 0 || len >= sizeof buf) { r->problem = @"bad number"; return nil; }
	memcpy(buf, start, len);
	buf[len] = 0;
	if (fraction) return [NSNumber numberWithDouble:strtod(buf, NULL)];
	return [NSNumber numberWithLongLong:strtoll(buf, NULL, 10)];
}

static BOOL WAReadLiteral(WAJSONReader *r, const char *word) {
	size_t n = strlen(word);
	if ((size_t)(r->end - r->p) < n || memcmp(r->p, word, n) != 0) return NO;
	r->p += n;
	return YES;
}

static id WAReadValue(WAJSONReader *r, int depth) {
	if (depth > 512) { r->problem = @"too deep"; return nil; }
	WASkipSpace(r);
	if (r->p >= r->end) { r->problem = @"unexpected end"; return nil; }
	unsigned char c = *r->p;
	BOOL mutableContainers = (r->options & NSJSONReadingMutableContainers) != 0;
	if (c == '{') {
		r->p++;
		NSMutableDictionary *d = [NSMutableDictionary dictionary];
		WASkipSpace(r);
		if (r->p < r->end && *r->p == '}') { r->p++; return mutableContainers ? d : [d copy]; }
		while (1) {
			WASkipSpace(r);
			if (r->p >= r->end || *r->p != '"') { r->problem = @"expected a key"; return nil; }
			NSString *key = WAReadString(r);
			if (!key) return nil;
			WASkipSpace(r);
			if (r->p >= r->end || *r->p != ':') { r->problem = @"expected ':'"; return nil; }
			r->p++;
			id value = WAReadValue(r, depth + 1);
			if (!value) return nil;
			[d setObject:value forKey:key];
			WASkipSpace(r);
			if (r->p < r->end && *r->p == ',') { r->p++; continue; }
			if (r->p < r->end && *r->p == '}') { r->p++; break; }
			r->problem = @"expected ',' or '}'";
			return nil;
		}
		return mutableContainers ? d : [d copy];
	}
	if (c == '[') {
		r->p++;
		NSMutableArray *a = [NSMutableArray array];
		WASkipSpace(r);
		if (r->p < r->end && *r->p == ']') { r->p++; return mutableContainers ? a : [a copy]; }
		while (1) {
			id value = WAReadValue(r, depth + 1);
			if (!value) return nil;
			[a addObject:value];
			WASkipSpace(r);
			if (r->p < r->end && *r->p == ',') { r->p++; continue; }
			if (r->p < r->end && *r->p == ']') { r->p++; break; }
			r->problem = @"expected ',' or ']'";
			return nil;
		}
		return mutableContainers ? a : [a copy];
	}
	if (c == '"') {
		NSString *s = WAReadString(r);
		return (s && !(r->options & NSJSONReadingMutableLeaves)) ? [s copy] : s;
	}
	if (c == '-' || (c >= '0' && c <= '9')) return WAReadNumber(r);
	if (WAReadLiteral(r, "true")) return (__bridge id)kCFBooleanTrue;
	if (WAReadLiteral(r, "false")) return (__bridge id)kCFBooleanFalse;
	if (WAReadLiteral(r, "null")) return [NSNull null];
	r->problem = @"unexpected character";
	return nil;
}

static NSError *WAJSONError(NSString *problem) {
	return [NSError errorWithDomain:NSCocoaErrorDomain code:3840
	                       userInfo:@{ NSLocalizedDescriptionKey: [@"JSON: " stringByAppendingString:problem ?: @"invalid"] }];
}

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
	if (!data) {
		if (error) *error = WAJSONError(@"no data");
		return nil;
	}
	WAJSONReader r = { data.bytes, (const unsigned char *)data.bytes + data.length, opt, nil };
	if (r.end - r.p >= 3 && r.p[0] == 0xEF && r.p[1] == 0xBB && r.p[2] == 0xBF) r.p += 3; // bom
	WASkipSpace(&r);
	if (r.p < r.end && *r.p != '{' && *r.p != '[' && !(opt & NSJSONReadingAllowFragments)) {
		if (error) *error = WAJSONError(@"top level is not an object or array");
		return nil;
	}
	id value = WAReadValue(&r, 0);
	if (value) {
		WASkipSpace(&r);
		if (r.p != r.end) { value = nil; r.problem = @"garbage after the value"; }
	}
	if (!value && error) *error = WAJSONError(r.problem);
	return value;
}

#pragma mark writing

static BOOL WAWrite(id obj, NSMutableData *out, int depth);

static void WAAppend(NSMutableData *out, const char *s) {
	[out appendBytes:s length:strlen(s)];
}

static void WAWriteString(NSString *s, NSMutableData *out) {
	WAAppend(out, "\"");
	NSUInteger n = s.length;
	unichar *buf = malloc(sizeof(unichar) * (n ? n : 1));
	[s getCharacters:buf range:NSMakeRange(0, n)];
	NSUInteger runStart = 0;
	for (NSUInteger i = 0; i < n; i++) {
		unichar c = buf[i];
		const char *esc = NULL;
		char hex[8];
		switch (c) {
			case '"': esc = "\\\""; break;
			case '\\': esc = "\\\\"; break;
			case '\n': esc = "\\n"; break;
			case '\r': esc = "\\r"; break;
			case '\t': esc = "\\t"; break;
			case '\b': esc = "\\b"; break;
			case '\f': esc = "\\f"; break;
			default:
				if (c < 0x20) { snprintf(hex, sizeof hex, "\\u%04x", c); esc = hex; }
		}
		if (!esc) continue;
		if (i > runStart)
			[out appendData:[[s substringWithRange:NSMakeRange(runStart, i - runStart)] dataUsingEncoding:NSUTF8StringEncoding]];
		WAAppend(out, esc);
		runStart = i + 1;
	}
	if (n > runStart)
		[out appendData:[[s substringWithRange:NSMakeRange(runStart, n - runStart)] dataUsingEncoding:NSUTF8StringEncoding]];
	free(buf);
	WAAppend(out, "\"");
}

static BOOL WAWrite(id obj, NSMutableData *out, int depth) {
	if (depth > 512) return NO;
	if ([obj isKindOfClass:[NSString class]]) { WAWriteString(obj, out); return YES; }
	if ([obj isKindOfClass:[NSNull class]]) { WAAppend(out, "null"); return YES; }
	if ([obj isKindOfClass:[NSNumber class]]) {
		if ((__bridge CFBooleanRef)obj == kCFBooleanTrue) { WAAppend(out, "true"); return YES; }
		if ((__bridge CFBooleanRef)obj == kCFBooleanFalse) { WAAppend(out, "false"); return YES; }
		const char *t = [obj objCType];
		char buf[40];
		if (t[0] == 'f' || t[0] == 'd') {
			double v = [obj doubleValue];
			if (v != v || v == 1.0 / 0.0 || v == -1.0 / 0.0) return NO; // no NaN/inf in json
			snprintf(buf, sizeof buf, "%.17g", v);
		} else if (t[0] == 'Q' || t[0] == 'L' || t[0] == 'I') {
			snprintf(buf, sizeof buf, "%llu", [obj unsignedLongLongValue]);
		} else {
			snprintf(buf, sizeof buf, "%lld", [obj longLongValue]);
		}
		WAAppend(out, buf);
		return YES;
	}
	if ([obj isKindOfClass:[NSArray class]]) {
		WAAppend(out, "[");
		BOOL first = YES;
		for (id v in obj) {
			if (!first) WAAppend(out, ",");
			first = NO;
			if (!WAWrite(v, out, depth + 1)) return NO;
		}
		WAAppend(out, "]");
		return YES;
	}
	if ([obj isKindOfClass:[NSDictionary class]]) {
		WAAppend(out, "{");
		BOOL first = YES;
		for (id k in obj) {
			if (![k isKindOfClass:[NSString class]]) return NO;
			if (!first) WAAppend(out, ",");
			first = NO;
			WAWriteString(k, out);
			WAAppend(out, ":");
			if (!WAWrite([obj objectForKey:k], out, depth + 1)) return NO;
		}
		WAAppend(out, "}");
		return YES;
	}
	return NO;
}

+ (NSData *)dataWithJSONObject:(id)obj options:(NSJSONWritingOptions)opt error:(NSError **)error {
	NSMutableData *out = [NSMutableData dataWithCapacity:256];
	if (![obj isKindOfClass:[NSArray class]] && ![obj isKindOfClass:[NSDictionary class]]) {
		if (error) *error = WAJSONError(@"top level is not an object or array");
		return nil;
	}
	if (!WAWrite(obj, out, 0)) {
		if (error) *error = WAJSONError(@"not JSON-serializable");
		return nil;
	}
	return out;
}

+ (BOOL)isValidJSONObject:(id)obj {
	if (![obj isKindOfClass:[NSArray class]] && ![obj isKindOfClass:[NSDictionary class]]) return NO;
	NSMutableData *scratch = [NSMutableData data];
	return WAWrite(obj, scratch, 0);
}

@end
#endif
