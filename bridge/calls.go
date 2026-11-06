package main

import (
	"bufio"
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/polymorfa/hypermeow/types"
	"github.com/purpshell/meowcaller"
	"github.com/purpshell/meowcaller/diag"
	"github.com/rs/zerolog"
)

// Voice calls. meowcaller does the whatsapp side (MLow, relays, SRTP), the phone just
// sends/receives 16khz ulaw over /api/call/audio.

// CallInfo is what the app shows.
type CallInfo struct {
	ID       string `json:"id"`
	Peer     string `json:"peer"`
	Name     string `json:"name"`
	Incoming bool   `json:"incoming"`
	State    string `json:"state"`
	Reason   string `json:"reason,omitempty"`
	Since    int64  `json:"since,omitempty"`    // unix
	Callback bool   `json:"callback,omitempty"` // callback mode
	// video state (see callvideo.go)
	Video       bool  `json:"video,omitempty"`
	PeerVideo   bool  `json:"peerVideo,omitempty"`
	Orientation int   `json:"orientation,omitempty"`
	Upd         int64 `json:"upd"`
}

type Calls struct {
	b       *Bridge
	mc      *meowcaller.Client
	mu      sync.Mutex
	call    *meowcaller.Call
	info    CallInfo
	pipe    *audioPipe
	vpipe   *videoPipe
	test    bool  // fake call from /api/debug/call
	started int64 // ringing since (unix)
}

func newCalls(b *Bridge) *Calls {
	level := zerolog.InfoLevel
	opts := []meowcaller.Option{}
	// debug: WA4S_CALL_DIAG=dir dumps all relay packets (incl. keys and audio!), delete afterwards
	if dir := os.Getenv("WA4S_CALL_DIAG"); dir != "" {
		if rec, err := diag.NewRecorder(dir); err == nil {
			opts = append(opts, meowcaller.WithDiagnostics(rec))
			level = zerolog.DebugLevel
			log.Printf("call diagnostics on: %s", dir)
		}
	}
	logger := zerolog.New(zerolog.ConsoleWriter{Out: os.Stderr, NoColor: true, TimeFormat: "15:04:05.000"}).
		Level(level).With().Timestamp().Str("mod", "call").Logger()
	c := &Calls{b: b, mc: meowcaller.NewClient(b.cli, append(opts, meowcaller.WithLogger(logger))...)}
	c.mc.OnIncomingCall(c.onIncoming)
	return c
}

func (c *Calls) onIncoming(call *meowcaller.Call) {
	c.mu.Lock()
	busy := c.call != nil && c.info.State != "ended"
	c.mu.Unlock()
	if busy {
		call.Reject()
		return
	}
	peer := c.b.chatKey(context.Background(), call.Peer())
	log.Printf("incoming call (video %v)", call.IsVideo())
	c.track(call, CallInfo{ID: call.ID(), Peer: peer.String(), Name: c.b.displayName(context.Background(), peer),
		Incoming: true, State: "ringing", Video: call.IsVideo(), PeerVideo: call.IsVideo()})
}

// track makes call the current one.
func (c *Calls) track(call *meowcaller.Call, info CallInfo) {
	pipe := newAudioPipe()
	// meowcaller only says active after the first decoded packet, real sound counts too
	pipe.onSound = func() { c.setState(call, "active", "") }
	vpipe := newVideoPipe(call, func(o int) { c.peerOrientation(call, o) })
	c.mu.Lock()
	if c.pipe != nil {
		c.pipe.close()
	}
	if c.vpipe != nil {
		c.vpipe.close()
	}
	c.call, c.info, c.pipe, c.vpipe, c.test, c.started = call, info, pipe, vpipe, false, time.Now().Unix()
	c.mu.Unlock()
	call.Play(pipe)
	call.Receive(pipe)
	call.OnVideoState(func(s meowcaller.VideoState) { c.peerVideoState(call, s) })
	call.OnStateChange(func(p meowcaller.CallPhase) {
		switch p {
		case meowcaller.CallPhaseConnecting:
			c.setState(call, "connecting", "")
		case meowcaller.CallPhaseActive:
			c.setState(call, "active", "")
		}
	})
	call.OnEnd(func(reason string) {
		log.Printf("call ended: %s", reason)
		c.setState(call, "ended", reason)
		pipe.close()
		vpipe.close()
	})
	c.bump()
}

func (c *Calls) setState(call *meowcaller.Call, state, reason string) {
	c.mu.Lock()
	if c.call != call || c.info.State == state {
		c.mu.Unlock()
		return
	}
	c.info.State = state
	c.info.Reason = reason
	if state == "active" && c.info.Since == 0 {
		c.info.Since = time.Now().Unix()
	}
	info, started := c.info, c.started
	c.mu.Unlock()
	if state == "ended" {
		c.record(info, started)
	}
	c.bump()
}

// record adds the finished call to its chat (kind "call", outcome in text, length in secs).
func (c *Calls) record(info CallInfo, started int64) {
	outcome, secs := "", 0
	reason := strings.ToLower(info.Reason)
	switch {
	case info.Since > 0:
		outcome, secs = "answered", int(time.Now().Unix()-info.Since)
	case info.Incoming && reason == "local":
		outcome = "declined"
	case info.Incoming && (strings.Contains(reason, "accept") || strings.Contains(reason, "elsewhere")):
		outcome = "elsewhere" // answered on another device
	case info.Incoming:
		outcome = "missed"
	case reason == "local":
		outcome = "cancelled"
	default:
		outcome = "unanswered"
	}
	if started == 0 {
		started = time.Now().Unix()
	}
	m := &Message{ID: "CALL" + info.ID, Chat: info.Peer, Sender: info.Peer, FromMe: !info.Incoming, TS: started,
		Kind: "call", Text: outcome, Status: statusRead, Secs: secs}
	if _, err := c.b.store.AddMessage(m, nil, outcome == "missed"); err != nil {
		log.Printf("call entry: %v", err)
	}
}

func (c *Calls) bump() {
	c.mu.Lock()
	c.info.Upd = c.b.store.next()
	c.mu.Unlock()
	c.b.store.notify()
}

// changedSince returns the call for the long poll, nil if unchanged.
func (c *Calls) changedSince(since int64) *CallInfo {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.info.ID == "" || c.info.Upd <= since {
		return nil
	}
	info := c.info
	return &info
}

func (c *Calls) apiState(w http.ResponseWriter, r *http.Request) {
	c.mu.Lock()
	info := c.info
	c.mu.Unlock()
	writeJSON(w, info)
}

func (c *Calls) apiStart(w http.ResponseWriter, r *http.Request) {
	jid, err := parseChat(r.FormValue("chat"))
	if err != nil || jid.Server != types.DefaultUserServer {
		http.Error(w, "a person's chat is needed", http.StatusBadRequest)
		return
	}
	c.mu.Lock()
	busy := c.call != nil && c.info.State != "ended"
	c.mu.Unlock()
	if busy {
		http.Error(w, "already in a call", http.StatusConflict)
		return
	}
	video := r.FormValue("video") == "1"
	call, err := c.mc.CallWithOptions(r.Context(), jid.String(), meowcaller.CallOptions{Video: video})
	if err != nil {
		httpErr(w, err, 502)
		return
	}
	// peer camera counts as on until it says otherwise
	c.track(call, CallInfo{ID: call.ID(), Peer: jid.String(), Name: c.b.displayName(r.Context(), jid), State: "calling",
		Video: video, PeerVideo: video})
	call.OnPeerAccept(func() { c.setState(call, "connecting", "") })
	c.apiState(w, r)
}

func (c *Calls) current() (*meowcaller.Call, CallInfo) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.call, c.info
}

func (c *Calls) apiAnswer(w http.ResponseWriter, r *http.Request) {
	call, info := c.current()
	if call == nil && c.isTest() && info.State == "ringing" {
		c.setState(nil, "active", "")
		go c.echo()
		c.apiState(w, r)
		return
	}
	if call == nil || info.State != "ringing" {
		http.Error(w, "no ringing call", http.StatusConflict)
		return
	}
	if os.Getenv("WA4S_CALL_ANSWER") == "callback" { // fallback, see callBack
		c.callBack(w, r, call, info)
		return
	}
	if err := call.Answer(); err != nil {
		httpErr(w, err, 502)
		return
	}
	c.setState(call, "connecting", "")
	c.apiState(w, r)
}

// callBack is the old workaround from before the callee fix (meowcaller #37/#40): decline and
// call back. Still there via WA4S_CALL_ANSWER=callback.
func (c *Calls) callBack(w http.ResponseWriter, r *http.Request, call *meowcaller.Call, info CallInfo) {
	c.mu.Lock()
	if c.call == call {
		c.call = nil // detach first so the app doesn't see "ended"
	}
	c.mu.Unlock()
	if err := call.Reject(); err != nil {
		log.Printf("call back: decline: %v", err)
	}
	jid, err := parseChat(info.Peer)
	if err != nil {
		c.failCallBack(w, r, info, "bad peer")
		return
	}
	// give the caller's phone a moment, whatsapp rejects calls right after its own call ended.
	// 0.7s wasn't always enough
	delay := 2500 * time.Millisecond
	if ms, err := strconv.Atoi(os.Getenv("WA4S_CALLBACK_DELAY_MS")); err == nil && ms >= 0 {
		delay = time.Duration(ms) * time.Millisecond
	}
	time.Sleep(delay)
	next, err := c.mc.CallWithOptions(r.Context(), jid.String(), meowcaller.CallOptions{Video: info.Video}) // video stays video
	if err != nil {
		log.Printf("call back: %v", err)
		c.failCallBack(w, r, info, "callback failed")
		return
	}
	log.Printf("call back placed")
	c.track(next, CallInfo{ID: next.ID(), Peer: info.Peer, Name: info.Name, State: "calling", Callback: true,
		Video: info.Video, PeerVideo: info.Video})
	next.OnPeerAccept(func() { c.setState(next, "connecting", "") })
	c.apiState(w, r)
}

func (c *Calls) failCallBack(w http.ResponseWriter, r *http.Request, info CallInfo, reason string) {
	c.mu.Lock()
	c.info.State, c.info.Reason = "ended", reason
	c.mu.Unlock()
	c.bump()
	c.apiState(w, r)
}

func (c *Calls) apiHangup(w http.ResponseWriter, r *http.Request) {
	call, info := c.current()
	if call == nil && c.isTest() && info.State != "ended" {
		c.endTest("local")
		c.apiState(w, r)
		return
	}
	if call == nil || info.State == "ended" {
		c.apiState(w, r)
		return
	}
	// before Hangup, its OnEnd would otherwise win and the chat says unanswered instead of cancelled
	c.setState(call, "ended", "local")
	var err error
	if info.State == "ringing" {
		err = call.Reject()
	} else {
		err = call.Hangup()
	}
	if err != nil {
		log.Printf("hangup: %v", err)
	}
	c.apiState(w, r)
}

func (c *Calls) isTest() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.test
}

// apiDebugCall fakes an incoming call from "WA4S Test" (state=ringing/ended).
// answering echoes your own audio back (~0.3s), good for testing the audio path
func (c *Calls) apiDebugCall(w http.ResponseWriter, r *http.Request) {
	if r.FormValue("state") == "ended" {
		if c.isTest() {
			c.endTest("remote")
		}
		c.apiState(w, r)
		return
	}
	c.mu.Lock()
	if c.call != nil && c.info.State != "ended" {
		c.mu.Unlock()
		http.Error(w, "already in a call", http.StatusConflict)
		return
	}
	if c.pipe != nil {
		c.pipe.close()
	}
	if c.vpipe != nil {
		c.vpipe.close()
	}
	video := r.FormValue("video") == "1" // video=1 echoes the camera too
	name := r.FormValue("name")
	if name == "" {
		name = "WA4S Test"
	}
	c.call, c.pipe, c.vpipe, c.test, c.started = nil, newAudioPipe(), newVideoPipe(nil, nil), true, time.Now().Unix()
	c.info = CallInfo{ID: fmt.Sprintf("TESTCALL%d", time.Now().UnixNano()), Peer: testChat, Name: name,
		Incoming: true, State: "ringing", Video: video, PeerVideo: video, Orientation: 1}
	c.mu.Unlock()
	c.bump()
	c.apiState(w, r)
}

func (c *Calls) endTest(reason string) {
	c.setState(nil, "ended", reason)
	c.mu.Lock()
	pipe, vpipe := c.pipe, c.vpipe
	c.mu.Unlock()
	pipe.close()
	vpipe.close()
}

func (c *Calls) echo() {
	c.mu.Lock()
	pipe := c.pipe
	c.mu.Unlock()
	t := time.NewTicker(60 * time.Millisecond)
	defer t.Stop()
	for range t.C {
		if pipe.isClosed() {
			return
		}
		frame, _ := pipe.ReadFrame()
		pipe.WriteFrame(frame)
	}
}

// apiAudio hijacks the connection as the audio socket.
func (c *Calls) apiAudio(w http.ResponseWriter, r *http.Request) {
	c.mu.Lock()
	pipe := c.pipe
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
	conn.SetDeadline(time.Time{}) // no header timeout for long calls
	rw.WriteString("HTTP/1.1 200 OK\r\nContent-Type: audio/basic\r\nConnection: close\r\n\r\n")
	rw.Flush()
	pipe.attach(conn, rw.Reader)
}

// audioPipe: call (60ms float frames) <-> phone (ulaw bytes).
type audioPipe struct {
	mu     sync.Mutex
	in     []float32
	conn   net.Conn
	out    chan []byte
	closed bool

	onSound                   func() // first frame with sound
	framesIn, framesOut, loud int
	lastLog                   time.Time
	// log stats: bytes out + zero crossing rate (speech ~0.05-0.2, wrong codec noise ~0.5)
	bytesToPhone   int
	crossings      float64
	crossingFrames int
}

func newAudioPipe() *audioPipe {
	return &audioPipe{out: make(chan []byte, 50)}
}

func (p *audioPipe) attach(conn net.Conn, r *bufio.Reader) {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		conn.Close()
		return
	}
	if p.conn != nil {
		p.conn.Close() // reconnected
	}
	p.conn = conn
	p.in = p.in[:0]
	p.mu.Unlock()
	log.Printf("call audio connected (%s)", conn.RemoteAddr())
	go func() {
		for data := range p.out {
			conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
			n, err := conn.Write(data)
			p.mu.Lock()
			p.bytesToPhone += n
			p.mu.Unlock()
			if err != nil {
				return
			}
		}
	}()
	buf := make([]byte, 1600)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			p.mu.Lock()
			for _, b := range buf[:n] {
				p.in = append(p.in, float32(ulawDecode(b))/32768)
			}
			// max 300ms, late audio is worse than lost audio
			if extra := len(p.in) - 4800; extra > 0 {
				p.in = append(p.in[:0], p.in[extra:]...)
			}
			p.mu.Unlock()
		}
		if err != nil {
			return
		}
	}
}

// ReadFrame returns the next 60ms from the phone or silence.
func (p *audioPipe) ReadFrame() ([]float32, error) {
	frame := make([]float32, meowcaller.FrameSamples)
	p.mu.Lock()
	p.framesOut++
	n := copy(frame, p.in)
	p.in = append(p.in[:0], p.in[n:]...)
	p.mu.Unlock()
	return frame, nil
}

// WriteFrame sends peer audio to the phone.
func (p *audioPipe) WriteFrame(frame []float32) error {
	data := make([]byte, len(frame))
	var peak float32
	for i, s := range frame {
		if s > peak {
			peak = s
		} else if -s > peak {
			peak = -s
		}
		v := s * 32767
		if v > 32767 {
			v = 32767
		} else if v < -32768 {
			v = -32768
		}
		data[i] = ulawEncode(int16(v))
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed { // can still get a frame after the end
		return nil
	}
	p.framesIn++
	if peak > 0.01 {
		if p.loud++; p.loud == 1 && p.onSound != nil {
			go p.onSound()
		}
		zc := 0
		for i := 1; i < len(frame); i++ {
			if (frame[i] >= 0) != (frame[i-1] >= 0) {
				zc++
			}
		}
		if len(frame) > 1 {
			p.crossings += float64(zc) / float64(len(frame)-1)
			p.crossingFrames++
		}
	}
	if time.Since(p.lastLog) > 10*time.Second {
		p.lastLog = time.Now()
		zcr := 0.0
		if p.crossingFrames > 0 {
			zcr = p.crossings / float64(p.crossingFrames)
		}
		log.Printf("call audio: %d frames from the peer (%d with sound, zero crossings %.2f), %d to the peer, iPhone %v (%d bytes sent to it)",
			p.framesIn, p.loud, zcr, p.framesOut, p.conn != nil, p.bytesToPhone)
		p.crossings, p.crossingFrames, p.bytesToPhone = 0, 0, 0
	}
	select {
	case p.out <- data:
	default: // phone not reading, drop
	}
	return nil
}

func (p *audioPipe) Close() error { return nil }

func (p *audioPipe) isClosed() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.closed
}

func (p *audioPipe) close() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return
	}
	p.closed = true
	close(p.out)
	if p.conn != nil {
		p.conn.Close()
	}
}

// ulaw
func ulawEncode(s int16) byte {
	const bias, clip = 0x84, 32635
	sign := byte(0)
	v := int(s)
	if v < 0 {
		v = -v
		sign = 0x80
	}
	if v > clip {
		v = clip
	}
	v += bias
	exp := 7
	for mask := 0x4000; v&mask == 0 && exp > 0; mask >>= 1 {
		exp--
	}
	mant := (v >> (exp + 3)) & 0x0F
	return ^(sign | byte(exp<<4) | byte(mant))
}

func ulawDecode(u byte) int16 {
	u = ^u
	sign := u & 0x80
	exp := int(u>>4) & 0x07
	mant := int(u & 0x0F)
	v := ((mant << 3) + 0x84) << exp
	v -= 0x84
	if sign != 0 {
		return int16(-v)
	}
	return int16(v)
}
