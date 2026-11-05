package main

import (
	"bytes"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"sync"
	"testing"
	"time"
)

// TestVideoLatency measures encoder/decoder latency at call frame rate. Needs ffmpeg:
// WA4S_LATENCY=1 go test -run VideoLatency -v
func TestVideoLatency(t *testing.T) {
	if os.Getenv("WA4S_LATENCY") == "" {
		t.Skip("set WA4S_LATENCY=1 to measure")
	}
	const peerFPS = 15 // iphones send ~15fps
	var jpegs, aus [][]byte
	splitJPEGs(bytes.NewReader(ffmpegOut(t, "352x288", videoFPS, "-c:v", "mjpeg", "-q:v", "5", "-f", "image2pipe")),
		func(j []byte) { jpegs = append(jpegs, j) })
	splitFLV(bytes.NewReader(ffmpegOut(t, "320x212", peerFPS, "-c:v", "libx264", "-profile:v", "main",
		"-bf", "0", "-g", "30", "-f", "flv")), func(au []byte) { aus = append(aus, au) })
	sendLat, sent := measureLatency(t, jpegs, videoFPS, encodeNoKey)
	t.Logf("send    (JPEG → H.264, %d fps): %s", videoFPS, sendLat)
	recvLat, _ := measureLatency(t, aus, peerFPS, decodeVideo)
	t.Logf("receive (H.264 → JPEG, %d fps): %s", peerFPS, recvLat)
	// encoder output must decode frame for frame
	if _, back := measureLatency(t, sent, peerFPS, decodeVideo); len(back) != len(sent) {
		t.Errorf("sent %d units, %d decoded", len(sent), len(back))
	}
}

// ffmpegOut makes 90 test frames.
func ffmpegOut(t *testing.T, size string, fps int, args ...string) []byte {
	args = append([]string{"-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=" + size + ":rate=" + strconv.Itoa(fps),
		"-frames:v", "90"}, append(args, "-")...)
	out, err := exec.Command("ffmpeg", args...).Output()
	if err != nil {
		t.Fatalf("ffmpeg: %v", err)
	}
	return out
}

// measureLatency returns median and p90 latency plus the output.
func measureLatency(t *testing.T, frames [][]byte, fps int, run func(<-chan []byte, <-chan struct{}, func([]byte))) (string, [][]byte) {
	in, stop := make(chan []byte, len(frames)), make(chan struct{})
	var mu sync.Mutex
	sent := make([]time.Time, len(frames))
	var got []time.Time
	var out [][]byte
	done := make(chan struct{})
	go func() {
		run(in, stop, func(b []byte) {
			mu.Lock()
			got = append(got, time.Now())
			out = append(out, b)
			mu.Unlock()
		})
		close(done)
	}()
	tick := time.NewTicker(time.Second / time.Duration(fps))
	for i, f := range frames {
		<-tick.C
		mu.Lock()
		sent[i] = time.Now()
		mu.Unlock()
		in <- f
	}
	tick.Stop()
	time.Sleep(time.Second)
	close(stop)
	<-done
	mu.Lock()
	defer mu.Unlock()
	var lat []time.Duration
	for i := 5; i < len(got) && i < len(sent); i++ { // includes ffmpeg startup
		lat = append(lat, got[i].Sub(sent[i]))
	}
	if len(lat) == 0 {
		t.Fatalf("no frames out (%d in)", len(frames))
	}
	sort.Slice(lat, func(a, b int) bool { return lat[a] < lat[b] })
	return "median " + lat[len(lat)/2].Round(time.Millisecond).String() + ", p90 " +
		lat[len(lat)*9/10].Round(time.Millisecond).String() + " (" + strconv.Itoa(len(got)) + "/" + strconv.Itoa(len(frames)) + " out)", out
}

func encodeNoKey(in <-chan []byte, stop <-chan struct{}, emit func([]byte)) {
	encodeVideo(in, nil, stop, func(au []byte, _ time.Duration) { emit(au) })
}

// TestVideoKeyframe: time from keyframe request to keyframe out.
func TestVideoKeyframe(t *testing.T) {
	if os.Getenv("WA4S_LATENCY") == "" {
		t.Skip("set WA4S_LATENCY=1 to measure")
	}
	var jpegs [][]byte
	splitJPEGs(bytes.NewReader(ffmpegOut(t, "352x288", videoFPS, "-c:v", "mjpeg", "-q:v", "5", "-f", "image2pipe")),
		func(j []byte) { jpegs = append(jpegs, j) })
	in, key, stop := make(chan []byte, len(jpegs)), make(chan struct{}, 1), make(chan struct{})
	var mu sync.Mutex
	var asked time.Time
	var waits []time.Duration
	done := make(chan struct{})
	go func() {
		encodeVideo(in, key, stop, func(au []byte, _ time.Duration) {
			mu.Lock()
			defer mu.Unlock()
			if !asked.IsZero() && bytes.Contains(au, []byte{0, 0, 0, 1, 0x65}) {
				waits = append(waits, time.Since(asked))
				asked = time.Time{}
			}
		})
		close(done)
	}()
	tick := time.NewTicker(time.Second / videoFPS)
	for i, f := range jpegs {
		<-tick.C
		if i%20 == 10 { // encoder keyframes every 2s
			mu.Lock()
			asked = time.Now()
			mu.Unlock()
			key <- struct{}{}
		}
		in <- f
	}
	tick.Stop()
	time.Sleep(time.Second)
	close(stop)
	<-done
	t.Logf("key frame after a request: %v", waits)
	if len(waits) < 3 {
		t.Errorf("only %d of the requests got a key frame", len(waits))
	}
}

// TestVideoCaptureGaps: camera times survive bursty input.
func TestVideoCaptureGaps(t *testing.T) {
	if os.Getenv("WA4S_LATENCY") == "" {
		t.Skip("set WA4S_LATENCY=1 to measure")
	}
	var jpegs [][]byte
	splitJPEGs(bytes.NewReader(ffmpegOut(t, "352x288", videoFPS, "-c:v", "mjpeg", "-q:v", "5", "-f", "image2pipe")),
		func(j []byte) { jpegs = append(jpegs, j) })
	in, stop := make(chan []byte, len(jpegs)), make(chan struct{})
	var mu sync.Mutex
	var gaps []time.Duration
	done := make(chan struct{})
	go func() {
		encodeVideo(in, nil, stop, func(_ []byte, gap time.Duration) {
			mu.Lock()
			gaps = append(gaps, gap)
			mu.Unlock()
		})
		close(done)
	}()
	for i, j := range jpegs[:30] {
		text := "WA4S t=" + strconv.Itoa(1000+i*66)
		tagged := append([]byte{0xFF, 0xD8, 0xFF, 0xFE, 0, byte(2 + len(text))}, text...)
		in <- append(tagged, j[2:]...)
		if i%3 == 2 { // burst of 3, then pause
			time.Sleep(200 * time.Millisecond)
		}
	}
	time.Sleep(time.Second)
	close(stop)
	<-done
	mu.Lock()
	defer mu.Unlock()
	if len(gaps) < 28 {
		t.Fatalf("%d units out of 30", len(gaps))
	}
	for i, g := range gaps[1:] { // skipped frame -> 132ms
		if g <= 0 || g%(66*time.Millisecond) != 0 {
			t.Errorf("unit %d: gap %v, want a multiple of 66ms", i+1, g)
		}
	}
}
