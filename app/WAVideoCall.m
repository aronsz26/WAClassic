#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <sys/socket.h>
#import "WAVideoCall.h"
#import "WACall.h"
#import "WAClient.h"
#import "WAUtil.h"

NSString *const WAVideoPictureNotification = @"WAVideoPictureNotification";

// fps: 30 on dual core (4s, 5), less on the 3gs since it also does audio
static int VideoFPS(void) {
	static int fps;
	if (!fps) fps = [NSProcessInfo processInfo].processorCount > 1 ? 30 : 15;
	return fps;
}
#define kFPS VideoFPS()
#define kMaxWidth 352 // downscale wider frames (3gs has no 352x288)
#define kMaxFrame (512 * 1024)

@interface WAVideoCall () <NSStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate>
@end

@implementation WAVideoCall {
	AVCaptureSession *_session;
	AVCaptureDeviceInput *_input;
	dispatch_queue_t _queue;
	volatile BOOL _capturing;
	volatile BOOL _holding; // hold frames after switching camera until orientation is sent
	CFAbsoluteTime _lastPicture;
	int _sentOrientation;
	NSInputStream *_in;
	NSOutputStream *_out;
	NSMutableData *_head, *_pending, *_incoming;
	BOOL _headDone, _requestSent, _tls;
	NSString *_callID;
	int _captured, _sent, _skipped, _received;
	volatile int _dropped, _worked; // stats
	volatile double _workTime;
}

+ (WAVideoCall *)shared {
	static WAVideoCall *video;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		video = [[WAVideoCall alloc] init];
		[[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
		[[NSNotificationCenter defaultCenter] addObserver:video selector:@selector(sendOrientation)
			name:UIDeviceOrientationDidChangeNotification object:nil];
	});
	return video;
}

- (AVCaptureSession *)session { return _capturing ? _session : nil; }

- (BOOL)frontCamera {
	return _input.device.position == AVCaptureDevicePositionFront;
}

- (BOOL)canSwitchCamera {
	return [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo].count > 1;
}

- (void)update {
	WACall *call = [WACall shared];
	BOOL want = call.live && ![call.state isEqualToString:@"ringing"] && (call.video || call.peerVideo)
		&& [call.info[@"id"] length];
	if (want && ![_callID isEqualToString:call.info[@"id"]]) {
		_callID = call.info[@"id"];
		_captured = _sent = _skipped = _received = _dropped = _worked = 0;
		_workTime = 0;
		_sentOrientation = -1;
		[self connect];
	} else if (!want && _callID) {
		WALog(@"call video: stopped (%d pictures from the camera, %d dropped by it, %.1f ms each as JPEG, %d sent, "
			"%d skipped while the socket was behind, %d received)", _captured, _dropped, _worked ? _workTime * 1000 / _worked : 0,
			_sent, _skipped, _received);
		_callID = nil;
		[self closeSocket];
	}
	BOOL camera = want && call.video;
	if (camera && !_capturing) [self startCamera];
	else if (!camera && _capturing) [self stopCamera];
}

#pragma mark - Camera

- (AVCaptureDevice *)cameraAt:(AVCaptureDevicePosition)position {
	for (AVCaptureDevice *d in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
		if (d.position == position) return d;
	}
	return nil;
}

- (void)startCamera {
	if (!_session) {
		_queue = dispatch_queue_create("com.aronsz26.wa4s.camera", NULL);
		_session = [[AVCaptureSession alloc] init];
		// preset constants are just their names, 352x288 is missing on ios 4
		for (NSString *preset in @[@"AVCaptureSessionPreset352x288", AVCaptureSessionPresetMedium, AVCaptureSessionPresetLow]) {
			if ([_session canSetSessionPreset:preset]) {
				_session.sessionPreset = preset;
				break;
			}
		}
		AVCaptureDevice *device = [self cameraAt:AVCaptureDevicePositionFront] ?: [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
		NSError *error = nil;
		_input = device ? [AVCaptureDeviceInput deviceInputWithDevice:device error:&error] : nil;
		if (!_input) {
			WALog(@"call video: no camera (%@)", error);
			_session = nil;
			return;
		}
		[_session addInput:_input];
		AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
		output.videoSettings = @{(__bridge id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
		output.alwaysDiscardsLateVideoFrames = YES;
		[output setSampleBufferDelegate:self queue:_queue];
		[_session addOutput:output];
		AVCaptureConnection *connection = [output connectionWithMediaType:AVMediaTypeVideo];
		if ([connection respondsToSelector:@selector(isVideoMinFrameDurationSupported)]) {
			if (connection.isVideoMinFrameDurationSupported) connection.videoMinFrameDuration = CMTimeMake(1, kFPS);
			// also cap min fps, it dropped to ~24 in low light
			if ([connection respondsToSelector:@selector(isVideoMaxFrameDurationSupported)] && connection.isVideoMaxFrameDurationSupported)
				connection.videoMaxFrameDuration = CMTimeMake(1, kFPS);
		} else if ([output respondsToSelector:@selector(setMinFrameDuration:)]) { // ios 4
			output.minFrameDuration = CMTimeMake(1, kFPS);
		}
	}
	_capturing = YES;
	[_session startRunning];
	WALog(@"call video: camera on (%@, %@)", self.frontCamera ? @"front" : @"back", _session.sessionPreset);
	_sentOrientation = -1;
	[self sendOrientation];
}

- (void)stopCamera {
	_capturing = NO;
	[_session stopRunning];
	WALog(@"call video: camera off");
}

- (void)switchCamera {
	if (!_session || !self.canSwitchCamera) return;
	AVCaptureDevice *next = [self cameraAt:self.frontCamera ? AVCaptureDevicePositionBack : AVCaptureDevicePositionFront];
	AVCaptureDeviceInput *input = next ? [AVCaptureDeviceInput deviceInputWithDevice:next error:NULL] : nil;
	if (!input) return;
	NSString *preset = _session.sessionPreset;
	[_session beginConfiguration];
	[_session removeInput:_input];
	BOOL added = NO;
	// other cam might not support the size, try the same order
	for (NSString *p in @[preset, @"AVCaptureSessionPreset352x288", AVCaptureSessionPresetMedium, AVCaptureSessionPresetLow]) {
		if (![_session canSetSessionPreset:p]) continue;
		_session.sessionPreset = p;
		if ([_session canAddInput:input]) {
			added = YES;
			break;
		}
	}
	if (added) {
		[_session addInput:input];
		_input = input;
	} else {
		_session.sessionPreset = preset;
		[_session addInput:_input];
	}
	// landscape flips between cams, hold frames until peer knows
	_holding = added && [self orientation] != _sentOrientation;
	[_session commitConfiguration];
	WALog(@"call video: switched to the %@ camera%@ (%@)", self.frontCamera ? @"front" : @"back", added ? @"" : @" - failed",
		_session.sessionPreset);
	[self sendOrientation];
}

// quarter turns clockwise for the peer. camera is landscape, front cam is mirrored
- (int)orientation {
	BOOL front = self.frontCamera;
	switch ([UIDevice currentDevice].orientation) {
		case UIDeviceOrientationLandscapeLeft: return front ? 2 : 0;
		case UIDeviceOrientationLandscapeRight: return front ? 0 : 2;
		case UIDeviceOrientationPortraitUpsideDown: return 3;
		case UIDeviceOrientationPortrait: return 1;
		default: return _sentOrientation >= 0 ? _sentOrientation : 1; // flat, keep last
	}
}

- (void)sendOrientation {
	if (!_capturing || !_callID) {
		_holding = NO;
		return;
	}
	int o = [self orientation];
	if (o == _sentOrientation) {
		_holding = NO;
		return;
	}
	_sentOrientation = o;
	[[WAClient shared] post:@"/api/call/orientation" params:@{@"o": [NSString stringWithFormat:@"%d", o]}
		completion:^(id json, NSError *error) {
			if (error) WALog(@"call video: orientation: %@", error.localizedDescription);
			if (o == _sentOrientation) _holding = NO;
		}];
}

// one jpeg per frame, max kFPS, skip if socket is behind
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample
		fromConnection:(AVCaptureConnection *)connection {
	if (!_capturing || _holding) return;
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (now - _lastPicture < 1.0 / kFPS - 0.01) return;
	_lastPicture = now;
	CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
	CVImageBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
	if (!pixels) return;
	CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
	size_t w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels);
	CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
	CGContextRef source = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixels), w, h, 8,
		CVPixelBufferGetBytesPerRow(pixels), space, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
	CGImageRef image = source ? CGBitmapContextCreateImage(source) : NULL;
	if (image && w > kMaxWidth) { // 3gs medium preset is 480x360
		size_t sw = kMaxWidth, sh = (h * kMaxWidth / w) & ~1;
		CGContextRef small = CGBitmapContextCreate(NULL, sw, sh, 8, 0, space, kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
		CGContextSetInterpolationQuality(small, kCGInterpolationLow);
		CGContextDrawImage(small, CGRectMake(0, 0, sw, sh), image);
		CGImageRelease(image);
		image = CGBitmapContextCreateImage(small);
		CGContextRelease(small);
	}
	NSMutableData *jpeg = [NSMutableData data];
	double ms = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 1000;
	if (image) {
		CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, CFSTR("public.jpeg"), 1, NULL);
		NSDictionary *options = @{(__bridge id)kCGImageDestinationLossyCompressionQuality: @0.45};
		CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)options);
		if (!CGImageDestinationFinalize(dest)) jpeg.length = 0;
		CFRelease(dest);
		CGImageRelease(image);
	}
	if (source) CGContextRelease(source);
	CGColorSpaceRelease(space);
	CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
	_workTime += CFAbsoluteTimeGetCurrent() - started;
	_worked++;
	if (jpeg.length < 4) return;
	// camera timestamp in a jpeg comment, bridge uses it for timing
	if (ms >= 0) {
		NSData *text = [[NSString stringWithFormat:@"WA4S t=%lld", (long long)ms] dataUsingEncoding:NSASCIIStringEncoding];
		uint8_t head[4] = {0xFF, 0xFE, (uint8_t)((text.length + 2) >> 8), (uint8_t)(text.length + 2)};
		NSMutableData *comment = [NSMutableData dataWithBytes:head length:4];
		[comment appendData:text];
		[jpeg replaceBytesInRange:NSMakeRange(2, 0) withBytes:comment.bytes length:comment.length];
	}
	dispatch_async(dispatch_get_main_queue(), ^{
		self->_captured++;
		[self sendPicture:jpeg];
	});
}

// ios 6 only
- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sample
		fromConnection:(AVCaptureConnection *)connection {
	_dropped++;
}

#pragma mark - Socket

- (void)sendPicture:(NSData *)jpeg {
	if (!_out || !_headDone) return;
	// skip while the last one is still sending, queues = lag
	if (_pending.length) {
		_skipped++;
		return;
	}
	uint32_t len = CFSwapInt32HostToBig((uint32_t)jpeg.length);
	[_pending appendBytes:&len length:4];
	[_pending appendData:jpeg];
	_sent++;
	[self flush];
}

- (void)connect {
	[self closeSocket];
	WAClient *client = [WAClient shared];
	NSURL *url = [NSURL URLWithString:client.serverURL];
	if (!url.host) return;
	_tls = [url.scheme isEqualToString:@"https"];
	int port = url.port ? url.port.intValue : (_tls ? 443 : 80);
	CFReadStreamRef readStream = NULL;
	CFWriteStreamRef writeStream = NULL;
	CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)url.host, port, &readStream, &writeStream);
	if (!readStream || !writeStream) return;
	if (_tls) {
		NSDictionary *ssl = @{(__bridge id)kCFStreamSSLValidatesCertificateChain: @NO,
			(__bridge id)kCFStreamSSLLevel: (__bridge id)kCFStreamSocketSecurityLevelNegotiatedSSL};
		CFReadStreamSetProperty(readStream, kCFStreamPropertySSLSettings, (__bridge CFDictionaryRef)ssl);
		CFWriteStreamSetProperty(writeStream, kCFStreamPropertySSLSettings, (__bridge CFDictionaryRef)ssl);
	}
	_in = CFBridgingRelease(readStream);
	_out = CFBridgingRelease(writeStream);
	_head = [NSMutableData data];
	_incoming = [NSMutableData data];
	_pending = [NSMutableData data];
	_headDone = _requestSent = NO;
	NSString *req = [NSString stringWithFormat:@"GET /api/call/video HTTP/1.0\r\nHost: %@:%d\r\nX-WA4S-Token: %@\r\n\r\n",
		url.host, port, client.token];
	[_pending appendData:[req dataUsingEncoding:NSUTF8StringEncoding]];
	for (NSStream *s in @[_in, _out]) {
		s.delegate = self;
		[s scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
		[s open];
	}
}

- (void)closeSocket {
	for (NSStream *s in @[_in ?: (id)[NSNull null], _out ?: (id)[NSNull null]]) {
		if ([s isKindOfClass:[NSNull class]]) continue;
		s.delegate = nil;
		[s close];
		[s removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
	}
	_in = nil;
	_out = nil;
	_headDone = NO;
}

- (void)reconnectSoon {
	[self closeSocket];
	NSString *call = _callID;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		if (call && [self->_callID isEqualToString:call] && !self->_in) [self connect];
	});
}

- (void)flush {
	if (!_pending.length || !_out.hasSpaceAvailable) return;
	if (!_requestSent && _tls) {
		SecTrustRef trust = (__bridge SecTrustRef)[_out propertyForKey:(__bridge NSString *)kCFStreamPropertySSLPeerTrust];
		if (!WAPinMatches(trust, [WAClient shared].pin)) {
			WALog(@"call video: certificate does not match the pin");
			[self closeSocket];
			return;
		}
	}
	NSInteger written = [_out write:_pending.bytes maxLength:_pending.length];
	if (written > 0) {
		[_pending replaceBytesInRange:NSMakeRange(0, written) withBytes:NULL length:0];
		_requestSent = YES;
	}
}

// peer frames: len + jpeg, only show the newest
- (void)readPictures {
	NSData *newest = nil;
	const uint8_t *bytes = _incoming.bytes;
	NSUInteger at = 0;
	while (_incoming.length - at >= 4) {
		uint32_t len = CFSwapInt32BigToHost(*(const uint32_t *)(bytes + at));
		if (len == 0 || len > kMaxFrame) {
			WALog(@"call video: bad picture length %u", len);
			[self reconnectSoon];
			return;
		}
		if (_incoming.length - at - 4 < len) break;
		newest = [_incoming subdataWithRange:NSMakeRange(at + 4, len)];
		at += 4 + len;
		_received++;
	}
	if (at) [_incoming replaceBytesInRange:NSMakeRange(0, at) withBytes:NULL length:0];
	UIImage *image = newest ? [UIImage imageWithData:newest] : nil;
	if (image) {
		[[NSNotificationCenter defaultCenter] postNotificationName:WAVideoPictureNotification object:self
			userInfo:@{@"image": image}];
	}
}

// small sndbuf + nodelay, don't let frames queue up
- (void)tuneSocket {
	CFDataRef handle = CFWriteStreamCopyProperty((__bridge CFWriteStreamRef)_out, kCFStreamPropertySocketNativeHandle);
	if (!handle) return;
	CFSocketNativeHandle fd = -1;
	if (CFDataGetLength(handle) == sizeof(fd)) CFDataGetBytes(handle, CFRangeMake(0, sizeof(fd)), (UInt8 *)&fd);
	CFRelease(handle);
	if (fd < 0) return;
	int buffer = 32 * 1024, on = 1;
	setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buffer, sizeof(buffer));
	setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
}

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)event {
	switch (event) {
		case NSStreamEventOpenCompleted:
			if (stream == _out) [self tuneSocket];
			break;
		case NSStreamEventHasSpaceAvailable:
			[self flush];
			break;
		case NSStreamEventHasBytesAvailable: {
			uint8_t buf[16384];
			NSInteger n;
			while (_in.hasBytesAvailable && (n = [_in read:buf maxLength:sizeof(buf)]) > 0) {
				if (_headDone) {
					[_incoming appendBytes:buf length:n];
					continue;
				}
				[_head appendBytes:buf length:n];
				NSRange r = [_head rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4] options:0 range:NSMakeRange(0, _head.length)];
				if (r.location == NSNotFound) continue;
				NSString *line = [[NSString alloc] initWithData:[_head subdataWithRange:NSMakeRange(0, MIN(r.location, (NSUInteger)20))]
					encoding:NSUTF8StringEncoding];
				if (![line hasPrefix:@"HTTP/1.1 200"] && ![line hasPrefix:@"HTTP/1.0 200"]) {
					WALog(@"call video refused: %@", line);
					[self reconnectSoon];
					return;
				}
				_headDone = YES;
				WALog(@"call video connected");
				NSUInteger rest = NSMaxRange(r);
				if (_head.length > rest) [_incoming appendBytes:(const uint8_t *)_head.bytes + rest length:_head.length - rest];
			}
			if (_headDone) [self readPictures];
			break;
		}
		case NSStreamEventEndEncountered:
		case NSStreamEventErrorOccurred:
			WALog(@"call video closed: %@", stream.streamError);
			[self reconnectSoon];
			break;
		default:
			break;
	}
}

@end
