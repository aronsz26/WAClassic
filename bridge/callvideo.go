package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"fmt"
	"image"
	"image/jpeg"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/purpshell/meowcaller"
)

// Video calls. Old iPhones can't encode h264 (no VideoToolbox before iOS 8), so the app sends jpegs
// over /api/call/video (4 byte BE length + jpeg, both ways) and ffmpeg converts to/from h264 for meowcaller.
// Frames stay landscape, orientation goes through the call state like whatsapp does it.

const (
	videoFPS      = 30
	maxVideoFrame = 512 << 10
)

// videoPipe connects one call's video (h264 AUs) with the iphone socket (jpegs).
type videoPipe struct {
	call *meowcaller.Call

	mu     sync.Mutex
	conn   net.Conn
	out    chan []byte   // to the phone, newest wins
	toEnc  chan []byte   // from the phone
	key    chan struct{} // peer wants a keyframe
	toDec  chan []byte   // from the peer
	encOn  bool
	decOn  bool
	closed bool
	stop   chan struct{}

	fromPhone, toPeer, fromPeer, toPhone int
	lastSent                             time.Time
	// stats for the log
	phoneBytes, phonePictures int
	keyRequests               int // keyframe requests (each restarts the encoder)
	bunched                   int // frames <10ms apart
	paceNext                  time.Time
	lastKept                  time.Duration
	lastPhone                 time.Time
	maxPhoneGap               time.Duration
	lastLog                   time.Time
}

// peerSink gets the peer video from meowcaller incl. the CVO rotation
// (whatsapp only sends it there when the call starts as video).
type peerSink struct {
	p             *videoPipe
	onOrientation func(clockwise int)
}

func (s peerSink) WriteVideo(au []byte) error {
	s.p.peerFrame(au)
	return nil
}

func (s peerSink) Close() error { return nil }

// SetOrientation: CVO counts counter-clockwise (3GPP TS 26.114), meowcaller's comment is wrong,
// tested with the iphone 5.
func (s peerSink) SetOrientation(cvo int) {
	log.Printf("call video: peer CVO %d", cvo)
	if s.onOrientation != nil {
		s.onOrientation((4 - cvo) & 3)
	}
}

func newVideoPipe(call *meowcaller.Call, onOrientation func(clockwise int)) *videoPipe {
	p := &videoPipe{call: call, out: make(chan []byte, 2), toEnc: make(chan []byte, 3), key: make(chan struct{}, 1), toDec: make(chan []byte, 60),
		stop: make(chan struct{})}
	if call != nil { // nil = test call (echoes the camera)
		call.ReceiveVideo(peerSink{p: p, onOrientation: onOrientation})
		call.OnVideoKeyframeRequest(p.keyframe)
	}
	return p
}

func (p *videoPipe) close() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return
	}
	p.closed = true
	close(p.stop)
	if p.conn != nil {
		p.conn.Close()
	}
}

// attach sets the phone's video socket, replacing the old one.
func (p *videoPipe) attach(conn net.Conn, r *bufio.Reader) {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		conn.Close()
		return
	}
	if p.conn != nil {
		p.conn.Close()
	}
	p.conn = conn
	p.mu.Unlock()
	log.Printf("call video: iPhone connected")
	done := make(chan struct{})
	go func() {
		defer conn.Close()
		head := make([]byte, 4)
		for {
			select {
			case jpeg := <-p.out:
				binary.BigEndian.PutUint32(head, uint32(len(jpeg)))
				conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
				if _, err := conn.Write(append(head, jpeg...)); err != nil {
					return
				}
			case <-done:
				return
			case <-p.stop:
				return
			}
		}
	}()
	defer close(done)
	head := make([]byte, 4)
	for {
		if _, err := io.ReadFull(r, head); err != nil {
			return
		}
		n := binary.BigEndian.Uint32(head)
		if n == 0 || n > maxVideoFrame {
			log.Printf("call video: bad frame length %d", n)
			return
		}
		jpeg := make([]byte, n)
		if _, err := io.ReadFull(r, jpeg); err != nil {
			return
		}
		p.phoneFrame(jpeg)
	}
}

// phoneFrame is one camera jpeg from the phone.
func (p *videoPipe) phoneFrame(jpeg []byte) {
	if p.call == nil {
		select {
		case p.out <- jpeg:
		default:
		}
		return
	}
	p.mu.Lock()
	p.fromPhone++
	p.phoneBytes += len(jpeg)
	p.phonePictures++
	now := time.Now()
	if !p.lastPhone.IsZero() && now.Sub(p.lastPhone) > p.maxPhoneGap {
		p.maxPhoneGap = now.Sub(p.lastPhone)
	}
	if !p.lastPhone.IsZero() && now.Sub(p.lastPhone) < 10*time.Millisecond {
		p.bunched++
	}
	p.lastPhone = now
	if p.skipForRate(jpeg, now) {
		p.mu.Unlock()
		return
	}
	start := !p.encOn
	p.encOn = true
	p.mu.Unlock()
	if start {
		go p.encode()
	}
	select {
	case p.toEnc <- jpeg:
	default: // encoder behind, skip
	}
}

// skipForRate drops frames above WA4S_VIDEO_MAX_FPS (debug). p.mu must be held.
func (p *videoPipe) skipForRate(jpeg []byte, now time.Time) bool {
	maxFPS, _ := strconv.Atoi(os.Getenv("WA4S_VIDEO_MAX_FPS"))
	if maxFPS <= 0 {
		return false
	}
	at, ok := captureTime(jpeg)
	if !ok {
		at = time.Duration(now.UnixNano())
	}
	if p.lastKept != 0 && at > p.lastKept && at-p.lastKept < time.Second/time.Duration(maxFPS)-5*time.Millisecond {
		return true
	}
	p.lastKept = at
	return false
}

// keyframe forces a new keyframe. meowcaller sends nothing until one comes and ffmpeg only
// makes one every 2s.
func (p *videoPipe) keyframe() {
	p.mu.Lock()
	p.keyRequests++
	p.mu.Unlock()
	select {
	case p.key <- struct{}{}:
	default:
	}
}

// peerFrame is one AU from the peer.
func (p *videoPipe) peerFrame(au []byte) {
	p.mu.Lock()
	p.fromPeer++
	start := !p.decOn
	p.decOn = true
	p.mu.Unlock()
	if start {
		log.Printf("call video: first frame from the peer")
		go p.decode()
	}
	select {
	case p.toDec <- append([]byte(nil), au...):
	default:
		log.Printf("call video: decoder is behind, dropped a frame")
	}
}

// encode sends the phone's frames to the peer until the call ends.
func (p *videoPipe) encode() {
	// queue + pace so one held unit doesn't block the encoder
	type unit struct {
		au   []byte
		step time.Duration
	}
	queue := make(chan unit, 60)
	sent := make(chan struct{})
	go func() {
		defer close(sent)
		for u := range queue {
			p.mu.Lock()
			wait := p.pace(u.step)
			p.mu.Unlock()
			if wait > 0 {
				time.Sleep(wait)
			}
			if err := p.call.SendVideoWithDuration(u.au, u.step); err != nil {
				p.logf("call video: send: %v", err)
				continue
			}
			p.mu.Lock()
			p.toPeer++
			p.mu.Unlock()
		}
	}()
	encodeVideo(p.toEnc, p.key, p.stop, func(au []byte, gap time.Duration) {
		p.mu.Lock()
		// use the camera timing if we have it, else arrival time (has wifi jitter)
		step := time.Second / videoFPS
		if gap > 20*time.Millisecond && gap < 500*time.Millisecond {
			step = gap
		} else if !p.lastSent.IsZero() {
			if d := time.Since(p.lastSent); d > 20*time.Millisecond && d < 500*time.Millisecond {
				step = d
			}
		}
		p.lastSent = time.Now()
		p.mu.Unlock()
		select {
		case queue <- unit{au, step}:
		default: // way too late, drop it
		}
	})
	close(queue)
	<-sent
	p.mu.Lock()
	p.encOn = false
	p.mu.Unlock()
}

// pace spreads units out like the camera took them, after WA4S_VIDEO_PACE_MS buffering
// (wifi delivers in bursts). A big stall resets the schedule. p.mu must be held.
func (p *videoPipe) pace(step time.Duration) time.Duration {
	ms, _ := strconv.Atoi(os.Getenv("WA4S_VIDEO_PACE_MS"))
	if ms <= 0 {
		return 0
	}
	buffer, now := time.Duration(ms)*time.Millisecond, time.Now()
	if p.paceNext.IsZero() || now.Sub(p.paceNext) > buffer {
		p.paceNext = now.Add(buffer)
	} else {
		p.paceNext = p.paceNext.Add(step)
	}
	return time.Until(p.paceNext)
}

// decode sends the peer's video to the phone until the call ends.
func (p *videoPipe) decode() {
	decodeVideo(p.toDec, p.stop, func(jpeg []byte) {
		select {
		case p.out <- jpeg:
		default: // phone behind, keep only the newest
			select {
			case <-p.out:
			default:
			}
			p.out <- jpeg
		}
		p.mu.Lock()
		p.toPhone++
		p.mu.Unlock()
		p.logf("")
	})
	p.mu.Lock()
	p.decOn = false
	p.mu.Unlock()
}

// encodeVideo: jpeg -> h264 baseline via ffmpeg. We decode the jpegs ourselves and pipe rawvideo,
// with an mjpeg pipe ffmpeg holds every frame back by one. A size change or keyframe request
// restarts ffmpeg. emit gets each AU plus the camera delta (0 = unknown).
func encodeVideo(in <-chan []byte, key <-chan struct{}, stop <-chan struct{}, emit func(au []byte, gap time.Duration)) {
	// camera times of frames inside ffmpeg
	var tmu sync.Mutex
	var times []time.Duration
	last := time.Duration(-1)
	queued := func(f rawFrame) {
		tmu.Lock()
		times = append(times, f.at)
		tmu.Unlock()
	}
	out := func(au []byte) {
		tmu.Lock()
		at := time.Duration(-1)
		if len(times) > 0 {
			at, times = times[0], times[1:]
		}
		var gap time.Duration
		if at >= 0 && last >= 0 && at > last {
			gap = at - last
		}
		if at >= 0 {
			last = at
		}
		tmu.Unlock()
		emit(au, gap)
	}
	decode := func(jpeg []byte) rawFrame {
		f := decodeRaw(jpeg)
		f.at = -1
		if at, ok := captureTime(jpeg); ok {
			f.at = at
		}
		return f
	}
	var next rawFrame
	for !next.ok() {
		select {
		case jpeg := <-in:
			next = decode(jpeg)
		case <-stop:
			return
		}
	}
	for next.ok() {
		format := next
		raw := make(chan []byte, 1)
		raw <- format.data
		queued(format)
		ended := make(chan struct{})
		started := time.Now()
		go func() { // same format stays on this ffmpeg
			defer close(ended)
			restart := false
			for {
				select {
				case <-key:
					// new ffmpeg starts with a keyframe anyway
					restart = time.Since(started) > 300*time.Millisecond
				case jpeg := <-in:
					f := decode(jpeg)
					if !f.ok() {
						continue
					}
					if restart || f.w != format.w || f.h != format.h || f.pixFmt != format.pixFmt {
						next = f
						return
					}
					select {
					case raw <- f.data:
						queued(f)
					default: // encoder behind, skip
					}
				case <-stop:
					next = rawFrame{}
					return
				}
			}
		}()
		cmd := exec.Command("ffmpeg", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", format.pixFmt,
			"-video_size", fmt.Sprintf("%dx%d", format.w, format.h), "-framerate", strconv.Itoa(videoFPS), "-i", "-",
			"-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-c:v", "libx264", "-profile:v", "baseline", "-level", "3.1",
			"-pix_fmt", "yuv420p", "-tune", "zerolatency", "-preset", "veryfast", "-b:v", "700k", "-maxrate", "900k",
			"-bufsize", "900k", "-g", strconv.Itoa(2*videoFPS), "-bf", "0", "-flush_packets", "1",
			"-f", "flv", "-flvflags", "no_duration_filesize", "-")
		runFFmpeg(cmd, raw, ended, nil, func(r io.Reader) { splitFLV(r, out) })
		<-ended
	}
}

// captureTime reads "WA4S t=<ms>" from the jpeg comment after SOI.
func captureTime(jpeg []byte) (time.Duration, bool) {
	if len(jpeg) < 6 || jpeg[0] != 0xFF || jpeg[1] != 0xD8 || jpeg[2] != 0xFF || jpeg[3] != 0xFE {
		return 0, false
	}
	n := int(binary.BigEndian.Uint16(jpeg[4:6]))
	if n < 2 || 4+n > len(jpeg) {
		return 0, false
	}
	ms, ok := strings.CutPrefix(strings.TrimRight(string(jpeg[6:4+n]), "\x00"), "WA4S t=")
	if !ok {
		return 0, false
	}
	v, err := strconv.ParseInt(ms, 10, 64)
	if err != nil || v < 0 {
		return 0, false
	}
	return time.Duration(v) * time.Millisecond, true
}

// rawFrame is a decoded frame in ffmpeg rawvideo layout.
type rawFrame struct {
	w, h   int
	pixFmt string
	data   []byte
	at     time.Duration // -1 = unknown
}

func (f rawFrame) ok() bool { return f.data != nil }

// decodeRaw turns a jpeg into a rawFrame (empty if unsupported).
func decodeRaw(jpegData []byte) rawFrame {
	img, err := jpeg.Decode(bytes.NewReader(jpegData))
	if err != nil {
		return rawFrame{}
	}
	b := img.Bounds()
	f := rawFrame{w: b.Dx(), h: b.Dy()}
	switch m := img.(type) {
	case *image.YCbCr:
		cw, ch := f.w, f.h
		switch m.SubsampleRatio {
		case image.YCbCrSubsampleRatio420:
			f.pixFmt, cw, ch = "yuv420p", (f.w+1)/2, (f.h+1)/2
		case image.YCbCrSubsampleRatio422:
			f.pixFmt, cw = "yuv422p", (f.w+1)/2
		case image.YCbCrSubsampleRatio440:
			f.pixFmt, ch = "yuv440p", (f.h+1)/2
		case image.YCbCrSubsampleRatio444:
			f.pixFmt = "yuv444p"
		default:
			return rawFrame{}
		}
		f.data = make([]byte, 0, f.w*f.h+2*cw*ch)
		f.data = appendPlane(f.data, m.Y, m.YStride, f.w, f.h)
		f.data = appendPlane(f.data, m.Cb, m.CStride, cw, ch)
		f.data = appendPlane(f.data, m.Cr, m.CStride, cw, ch)
	case *image.Gray:
		f.pixFmt = "gray"
		f.data = appendPlane(make([]byte, 0, f.w*f.h), m.Pix, m.Stride, f.w, f.h)
	default:
		return rawFrame{}
	}
	return f
}

func appendPlane(dst, pix []byte, stride, w, h int) []byte {
	for y := 0; y < h; y++ {
		dst = append(dst, pix[y*stride:y*stride+w]...)
	}
	return dst
}

// decodeVideo: h264 -> jpeg (max 480px) via ffmpeg.
func decodeVideo(in <-chan []byte, stop <-chan struct{}, emit func(jpeg []byte)) {
	// don't use -fflags nobuffer, it adds ~2s delay
	cmd := exec.Command("ffmpeg", "-loglevel", "error", "-probesize", "32", "-analyzeduration", "0",
		"-flags", "low_delay", "-f", "h264", "-i", "-",
		"-vf", "scale='min(480,iw)':'min(480,ih)':force_original_aspect_ratio=decrease",
		"-c:v", "mjpeg", "-q:v", "6", "-fps_mode", "passthrough", "-flush_packets", "1", "-f", "image2pipe", "-")
	// AUD after every unit, otherwise ffmpeg waits for the next frame
	// (the "missing picture in access unit" at the end is harmless)
	runFFmpeg(cmd, in, stop, []byte{0, 0, 0, 1, 9, 0xf0}, func(out io.Reader) { splitJPEGs(out, emit) })
}

// runFFmpeg runs cmd, feeds it from in until stop and passes stdout to read.
func runFFmpeg(cmd *exec.Cmd, in <-chan []byte, stop <-chan struct{}, after []byte, read func(io.Reader)) {
	stdin, err := cmd.StdinPipe()
	if err != nil {
		log.Printf("call video: %v", err)
		return
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		log.Printf("call video: %v", err)
		return
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		log.Printf("call video: ffmpeg: %v", err)
		return
	}
	go func() {
		defer stdin.Close()
		for {
			select {
			case b := <-in:
				if _, err := stdin.Write(append(b, after...)); err != nil {
					return
				}
			case <-stop:
				return
			}
		}
	}()
	read(stdout)
	cmd.Process.Kill()
	cmd.Wait()
}

// logf logs at most every 10s, with the frame counters.
func (p *videoPipe) logf(format string, args ...any) {
	p.mu.Lock()
	if time.Since(p.lastLog) < 10*time.Second {
		p.mu.Unlock()
		return
	}
	p.lastLog = time.Now()
	avg := 0
	if p.phonePictures > 0 {
		avg = p.phoneBytes / p.phonePictures
	}
	counts := []any{p.fromPhone, p.toPeer, p.fromPeer, p.toPhone, avg / 1024, p.maxPhoneGap.Milliseconds(), p.bunched,
		p.keyRequests}
	p.phoneBytes, p.phonePictures, p.maxPhoneGap, p.keyRequests, p.bunched = 0, 0, 0, 0, 0
	p.mu.Unlock()
	if format != "" {
		log.Printf(format, args...)
	}
	log.Printf("call video: iPhone %d → peer %d, peer %d → iPhone %d (iPhone pictures %d KB, longest wait %d ms, %d bunched, key frames asked %d)", counts...)
}

// apiVideo hijacks the connection as the video socket.
func (c *Calls) apiVideo(w http.ResponseWriter, r *http.Request) {
	c.mu.Lock()
	pipe := c.vpipe
	c.mu.Unlock()
	if pipe == nil {
		http.Error(w, "no call", http.StatusConflict)
		return
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "no raw connection", http.StatusInternalServerError)
		return
	}
	conn, rw, err := hj.Hijack()
	if err != nil {
		return
	}
	conn.SetDeadline(time.Time{})
	rw.WriteString("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n")
	rw.Flush()
	pipe.attach(conn, rw.Reader)
}

// apiCamera turns the phone camera on/off. On during a voice call = ask for video.
func (c *Calls) apiCamera(w http.ResponseWriter, r *http.Request) {
	call, info := c.current()
	if call == nil || info.State == "ended" {
		http.Error(w, "no call", http.StatusConflict)
		return
	}
	on := r.FormValue("on") == "1"
	var err error
	switch {
	case call.IsSendingVideo() || (!on && info.Video):
		err = call.SetVideoEnabled(on)
	case on:
		err = call.StartVideo()
	}
	if err != nil {
		httpErr(w, err, 502)
		return
	}
	c.mu.Lock()
	if c.call == call {
		c.info.Video = on
		if on && c.vpipe != nil { // meowcaller waits for a keyframe after camera off
			c.vpipe.keyframe()
		}
	}
	c.mu.Unlock()
	c.bump()
	c.apiState(w, r)
}

// apiOrientation: quarter turns clockwise (o=0..3).
func (c *Calls) apiOrientation(w http.ResponseWriter, r *http.Request) {
	call, _ := c.current()
	o, err := strconv.Atoi(r.FormValue("o"))
	if call == nil && err == nil && c.isTest() {
		c.mu.Lock()
		c.info.Orientation = o & 3
		c.mu.Unlock()
		c.bump()
		writeJSON(w, map[string]bool{"ok": true})
		return
	}
	if call == nil || err != nil || o < 0 || o > 3 {
		http.Error(w, "no call or bad orientation", http.StatusBadRequest)
		return
	}
	if err := call.SetVideoOrientation(o); err != nil {
		httpErr(w, err, 502)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

// peerVideoState tracks the peer camera. Upgrade requests are accepted right away,
// our camera stays off until the phone turns it on.
func (c *Calls) peerVideoState(call *meowcaller.Call, s meowcaller.VideoState) {
	if s.Upgrade {
		if err := call.AcceptVideo(); err != nil {
			log.Printf("call video: accept upgrade: %v", err)
		}
	}
	c.mu.Lock()
	if c.call != call {
		c.mu.Unlock()
		return
	}
	changed := c.info.PeerVideo != (s.Active || s.Upgrade) || c.info.Orientation != s.Orientation
	c.info.PeerVideo = s.Active || s.Upgrade
	c.info.Orientation = s.Orientation
	c.mu.Unlock()
	if changed {
		log.Printf("call video: peer camera %v, orientation %d", s.Active || s.Upgrade, s.Orientation)
		c.bump()
	}
}

// peerOrientation tracks the CVO of the peer frames.
func (c *Calls) peerOrientation(call *meowcaller.Call, o int) {
	c.mu.Lock()
	changed := c.call == call && c.info.Orientation != o
	if changed {
		c.info.Orientation = o
	}
	c.mu.Unlock()
	if changed {
		log.Printf("call video: peer orientation %d (from the video)", o)
		c.bump()
	}
}

// splitFLV reads ffmpeg's flv output and emits annex-b AUs, SPS/PPS before keyframes.
// FLV has the lengths up front, raw h264 would delay each frame by one.
func splitFLV(r io.Reader, fn func([]byte)) {
	br := bufio.NewReaderSize(r, 1<<16)
	head := make([]byte, 9)
	if _, err := io.ReadFull(br, head); err != nil || string(head[:3]) != "FLV" {
		return
	}
	if skip := int(binary.BigEndian.Uint32(head[5:])) - 9; skip > 0 {
		br.Discard(skip)
	}
	var headers []byte // sps + pps, annex-b
	tag := make([]byte, 15)
	for {
		if _, err := io.ReadFull(br, tag); err != nil {
			return
		}
		size := int(tag[5])<<16 | int(tag[6])<<8 | int(tag[7])
		data := make([]byte, size)
		if _, err := io.ReadFull(br, data); err != nil {
			return
		}
		if tag[4] != 9 || size < 5 || data[0]&0x0f != 7 {
			continue
		}
		key, body := data[0]>>4 == 1, data[5:]
		switch data[1] {
		case 0: // AVCDecoderConfigurationRecord
			headers = nil
			if len(body) > 5 {
				rest := paramSets(body[5:], int(body[5]&0x1f), &headers)
				if len(rest) > 0 {
					paramSets(rest, int(rest[0]), &headers)
				}
			}
		case 1: // length prefixed NALs
			var au []byte
			hasSPS := false
			for len(body) >= 4 {
				n := int(binary.BigEndian.Uint32(body))
				if n <= 0 || len(body) < 4+n {
					break
				}
				nal := body[4 : 4+n]
				body = body[4+n:]
				switch nal[0] & 0x1f {
				case 9: // AUD
					continue
				case 7:
					hasSPS = true
				}
				au = append(append(au, 0, 0, 0, 1), nal...)
			}
			if key && !hasSPS {
				au = append(append([]byte(nil), headers...), au...)
			}
			if len(au) > 0 {
				fn(au)
			}
		}
	}
}

// paramSets copies count param sets (2 byte length each) as annex-b, returns the rest.
func paramSets(b []byte, count int, dst *[]byte) []byte {
	b = b[1:]
	for ; count > 0 && len(b) >= 2; count-- {
		n := int(binary.BigEndian.Uint16(b))
		if len(b) < 2+n {
			return nil
		}
		*dst = append(append(*dst, 0, 0, 0, 1), b[2:2+n]...)
		b = b[2+n:]
	}
	return b
}

// splitJPEGs splits image2pipe output at SOI/EOI (FF D9 can't appear inside).
func splitJPEGs(r io.Reader, fn func([]byte)) {
	br := bufio.NewReaderSize(r, 1<<20)
	var buf []byte
	chunk := make([]byte, 64<<10)
	for {
		n, err := br.Read(chunk)
		buf = append(buf, chunk[:n]...)
		for {
			start := bytes.Index(buf, []byte{0xFF, 0xD8})
			if start < 0 {
				buf = buf[:0]
				break
			}
			end := bytes.Index(buf[start+2:], []byte{0xFF, 0xD9})
			if end < 0 {
				buf = buf[start:]
				break
			}
			stop := start + 2 + end + 2
			fn(append([]byte(nil), buf[start:stop]...))
			buf = buf[stop:]
		}
		if err != nil {
			return
		}
	}
}
