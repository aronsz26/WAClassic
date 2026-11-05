#import "WAUtil.h"

static NSDateFormatter *Formatter(NSString *format) {
	NSDateFormatter *f = [[NSDateFormatter alloc] init];
	f.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_GB"];
	f.dateFormat = format;
	return f;
}

NSString *WAClockTime(long long ts) {
	static NSDateFormatter *f;
	if (!f) f = Formatter(@"HH:mm");
	return [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:ts]];
}

NSString *WAShortTime(long long ts) {
	static NSDateFormatter *weekday, *date;
	if (!weekday) {
		weekday = Formatter(@"EEEE");
		date = Formatter(@"dd/MM/yy");
	}
	NSDate *d = [NSDate dateWithTimeIntervalSince1970:ts];
	NSCalendar *cal = [NSCalendar currentCalendar];
	NSDate *today = nil;
	[cal rangeOfUnit:NSDayCalendarUnit startDate:&today interval:NULL forDate:[NSDate date]];
	NSTimeInterval diff = [d timeIntervalSinceDate:today];
	if (diff >= 0) return WAClockTime(ts);
	if (diff >= -86400) return @"Yesterday";
	if (diff >= -6 * 86400) return [weekday stringFromDate:d];
	return [date stringFromDate:d];
}

NSString *WALastSeen(long long ts) {
	NSDate *d = [NSDate dateWithTimeIntervalSince1970:ts];
	NSDate *today = nil;
	[[NSCalendar currentCalendar] rangeOfUnit:NSDayCalendarUnit startDate:&today interval:NULL forDate:[NSDate date]];
	NSTimeInterval diff = [d timeIntervalSinceDate:today];
	if (diff >= 0) return [NSString stringWithFormat:@"last seen today at %@", WAClockTime(ts)];
	if (diff >= -86400) return [NSString stringWithFormat:@"last seen yesterday at %@", WAClockTime(ts)];
	return [NSString stringWithFormat:@"last seen %@ at %@", WAShortTime(ts), WAClockTime(ts)];
}

NSString *WAFutureTime(long long ts) {
	static NSDateFormatter *date;
	if (!date) date = Formatter(@"dd/MM/yy");
	if (ts - [[NSDate date] timeIntervalSince1970] < 86400) return WAClockTime(ts);
	return [date stringFromDate:[NSDate dateWithTimeIntervalSince1970:ts]];
}

NSString *WAKindLabel(NSString *kind) {
	static NSDictionary *labels;
	if (!labels) labels = @{@"image": @"Photo", @"video": @"Video", @"audio": @"Audio", @"sticker": @"Sticker",
		@"document": @"Document", @"location": @"Location", @"contact": @"Contact", @"call": @"Voice call"};
	return labels[kind] ?: @"Message";
}

NSString *WACallText(NSDictionary *m) {
	NSString *outcome = m[@"text"];
	BOOL mine = [m[@"fromMe"] boolValue];
	if ([outcome isEqualToString:@"answered"]) {
		NSInteger secs = [m[@"secs"] integerValue];
		NSString *len = secs >= 3600 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(secs / 3600), (long)(secs / 60 % 60), (long)(secs % 60)]
			: [NSString stringWithFormat:@"%ld:%02ld", (long)(secs / 60), (long)(secs % 60)];
		return [NSString stringWithFormat:@"%@ voice call · %@", mine ? @"Outgoing" : @"Incoming", len];
	}
	if ([outcome isEqualToString:@"missed"]) return @"Missed voice call";
	if ([outcome isEqualToString:@"declined"]) return @"Declined voice call";
	if ([outcome isEqualToString:@"elsewhere"]) return @"Voice call on another device";
	if ([outcome isEqualToString:@"cancelled"]) return @"Cancelled voice call";
	if ([outcome isEqualToString:@"unanswered"]) return @"Voice call not answered";
	return @"Voice call";
}

UIColor *WAColor(unsigned rgb) {
	return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0 blue:(rgb & 0xFF) / 255.0 alpha:1];
}

UIColor *WANameColor(NSString *jid) {
	static const unsigned colors[] = {0xC0392B, 0x2471A3, 0x1E8449, 0xA04000, 0x7D3C98, 0x117A65, 0xB7950B, 0x6E2C00};
	NSUInteger h = jid.hash;
	return WAColor(colors[h % (sizeof(colors) / sizeof(colors[0]))]);
}

void WALog(NSString *format, ...) {
	va_list args;
	va_start(args, format);
	NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
	va_end(args);
	static NSDateFormatter *f;
	if (!f) {
		f = [[NSDateFormatter alloc] init];
		f.dateFormat = @"HH:mm:ss";
	}
	NSString *path = @"/var/mobile/Library/WA4S/log.txt";
	NSString *line = [NSString stringWithFormat:@"%@ [%d] %@\n", [f stringFromDate:[NSDate date]],
		(int)[UIApplication sharedApplication].applicationState, msg];
	NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
	if (!h) {
		[line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
		return;
	}
	if ([h seekToEndOfFile] > 200000) {
		[h truncateFileAtOffset:0];
	}
	[h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
	[h closeFile];
}

NSString *WAEmojiForDisplay(NSString *emoji) {
	if (!emoji.length) return emoji;
	NSMutableString *out = [NSMutableString string];
	NSUInteger i = 0;
	while (i < emoji.length) {
		NSRange r = [emoji rangeOfComposedCharacterSequenceAtIndex:i];
		// drop FE0E/FE0F and skin tones
		for (NSUInteger j = r.location; j < NSMaxRange(r);) {
			unichar c = [emoji characterAtIndex:j];
			if (CFStringIsSurrogateHighCharacter(c) && j + 1 < NSMaxRange(r)) {
				unichar lo = [emoji characterAtIndex:j + 1];
				UTF32Char cp = CFStringGetLongCharacterForSurrogatePair(c, lo);
				if (cp < 0x1F3FB || cp > 0x1F3FF) [out appendString:[emoji substringWithRange:NSMakeRange(j, 2)]];
				j += 2;
			} else {
				if (c != 0xFE0E && c != 0xFE0F) [out appendFormat:@"%C", c];
				j++;
			}
		}
		i = NSMaxRange(r);
	}
	return out.length ? out : emoji;
}
