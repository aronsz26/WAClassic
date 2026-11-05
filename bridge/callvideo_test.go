package main

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/jpeg"
	"strconv"
	"testing"
	"time"
)

func TestSplitFLV(t *testing.T) {
	sps, pps := []byte{0x67, 1, 2}, []byte{0x68, 3}
	idr, p, aud := []byte{0x65, 4, 5}, []byte{0x41, 6}, []byte{9, 0xf0}
	nals := func(n ...[]byte) []byte {
		var b []byte
		for _, x := range n {
			b = binary.BigEndian.AppendUint32(b, uint32(len(x)))
			b = append(b, x...)
		}
		return b
	}
	var stream bytes.Buffer
	stream.Write([]byte{'F', 'L', 'V', 1, 1, 0, 0, 0, 9})
	tag := func(kind byte, data []byte) {
		stream.Write([]byte{0, 0, 0, 0, kind, byte(len(data) >> 16), byte(len(data) >> 8), byte(len(data)), 0, 0, 0, 0, 0, 0, 0})
		stream.Write(data)
	}
	tag(18, []byte("onMetaData"))
	config := append([]byte{1, 66, 0, 31, 0xff, 0xe1, 0, byte(len(sps))}, sps...)
	config = append(append(config, 1, 0, byte(len(pps))), pps...)
	tag(9, append([]byte{0x17, 0, 0, 0, 0}, config...))
	tag(9, append([]byte{0x17, 1, 0, 0, 0}, nals(aud, idr)...))
	tag(9, append([]byte{0x27, 1, 0, 0, 0}, nals(aud, p)...))
	var got [][]byte
	splitFLV(&stream, func(au []byte) { got = append(got, au) })
	sc := []byte{0, 0, 0, 1}
	want := [][]byte{bytes.Join([][]byte{nil, sps, pps, idr}, sc), append(append([]byte{}, sc...), p...)}
	if len(got) != len(want) {
		t.Fatalf("got %d units, want %d", len(got), len(want))
	}
	for i := range want {
		if !bytes.Equal(got[i], want[i]) {
			t.Errorf("unit %d = %x, want %x", i, got[i], want[i])
		}
	}
}

func TestSplitJPEGs(t *testing.T) {
	a := []byte{0xFF, 0xD8, 1, 0xFF, 0x00, 2, 0xFF, 0xD9}
	b := []byte{0xFF, 0xD8, 3, 0xFF, 0xD9}
	var got [][]byte
	splitJPEGs(bytes.NewReader(append(append([]byte{}, a...), b...)), func(j []byte) { got = append(got, j) })
	if len(got) != 2 || !bytes.Equal(got[0], a) || !bytes.Equal(got[1], b) {
		t.Fatalf("got %x", got)
	}
}

func TestDecodeRaw(t *testing.T) {
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, image.NewYCbCr(image.Rect(0, 0, 35, 29), image.YCbCrSubsampleRatio420), nil); err != nil {
		t.Fatal(err)
	}
	f := decodeRaw(buf.Bytes())
	if f.w != 35 || f.h != 29 || f.pixFmt != "yuv420p" || len(f.data) != 35*29+2*18*15 {
		t.Fatalf("got %dx%d %s, %d bytes", f.w, f.h, f.pixFmt, len(f.data))
	}
	if decodeRaw([]byte("no picture")).ok() {
		t.Fatal("decoded garbage")
	}
}

func TestCaptureTime(t *testing.T) {
	text := "WA4S t=123456"
	jpeg := append([]byte{0xFF, 0xD8, 0xFF, 0xFE, 0, byte(2 + len(text))}, text...)
	jpeg = append(jpeg, 0xFF, 0xD9)
	if at, ok := captureTime(jpeg); !ok || at != 123456*time.Millisecond {
		t.Fatalf("got %v %v", at, ok)
	}
	if _, ok := captureTime([]byte{0xFF, 0xD8, 0xFF, 0xE0, 0, 4, 1, 2}); ok {
		t.Fatal("a JPEG without the comment has a time")
	}
}

func TestPace(t *testing.T) {
	t.Setenv("WA4S_VIDEO_PACE_MS", "100")
	p := &videoPipe{}
	start := time.Now()
	// burst of 3, 33ms apart
	var sendAt []time.Duration
	for i := 0; i < 3; i++ {
		wait := p.pace(33 * time.Millisecond)
		sendAt = append(sendAt, time.Since(start)+wait)
	}
	for i, want := range []time.Duration{100, 133, 166} {
		if d := sendAt[i] - want*time.Millisecond; d < -5*time.Millisecond || d > 5*time.Millisecond {
			t.Errorf("unit %d leaves at %v, want about %v ms", i, sendAt[i], want)
		}
	}
	// long stall resets
	p.paceNext = time.Now().Add(-time.Second)
	if wait := p.pace(33 * time.Millisecond); wait < 90*time.Millisecond {
		t.Errorf("after a stall it waits %v, want the buffer again", wait)
	}
	t.Setenv("WA4S_VIDEO_PACE_MS", "")
	if wait := (&videoPipe{}).pace(33 * time.Millisecond); wait != 0 {
		t.Errorf("off: waits %v", wait)
	}
}

func TestSkipForRate(t *testing.T) {
	t.Setenv("WA4S_VIDEO_MAX_FPS", "15")
	p := &videoPipe{}
	kept := 0
	for i := 0; i < 30; i++ { // 1s at 30fps
		text := "WA4S t=" + strconv.Itoa(1000+i*33)
		jpeg := append([]byte{0xFF, 0xD8, 0xFF, 0xFE, 0, byte(2 + len(text))}, text...)
		if !p.skipForRate(jpeg, time.Now()) {
			kept++
		}
	}
	if kept != 15 {
		t.Fatalf("kept %d of 30, want 15", kept)
	}
}
