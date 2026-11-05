package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"io"
	"log"
	"math"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/polymorfa/hypermeow"
	"github.com/polymorfa/hypermeow/proto/waE2E"
	"golang.org/x/image/draw"
	"google.golang.org/protobuf/proto"
)

// ffmpeg needs a seekable output file for mp4/m4a/ogg, so use a temp dir
func ffmpeg(ctx context.Context, in []byte, inName, outName string, args ...string) ([]byte, error) {
	dir, err := os.MkdirTemp("", "wa4s-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	inPath, outPath := filepath.Join(dir, inName), filepath.Join(dir, outName)
	if err := os.WriteFile(inPath, in, 0o600); err != nil {
		return nil, err
	}
	full := append([]string{"-hide_banner", "-loglevel", "error", "-y", "-i", inPath}, args...)
	full = append(full, outPath)
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	if out, err := exec.CommandContext(ctx, "ffmpeg", full...).CombinedOutput(); err != nil {
		return nil, fmt.Errorf("ffmpeg: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return os.ReadFile(outPath)
}

// duration via ffprobe.
func duration(ctx context.Context, data []byte, name string) int {
	dir, err := os.MkdirTemp("", "wa4s-")
	if err != nil {
		return 0
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, name)
	if os.WriteFile(path, data, 0o600) != nil {
		return 0
	}
	out, err := exec.CommandContext(ctx, "ffprobe", "-v", "error", "-show_entries", "format=duration",
		"-of", "default=noprint_wrappers=1:nokey=1", path).Output()
	if err != nil {
		return 0
	}
	f, err := strconv.ParseFloat(strings.TrimSpace(string(out)), 64)
	if err != nil {
		return 0
	}
	return int(math.Round(f))
}

// serveAudioM4A converts opus/ogg voice notes to aac m4a for iOS 6.
func (b *Bridge) serveAudioM4A(w http.ResponseWriter, r *http.Request, seq int64, dl whatsmeow.DownloadableMessage) {
	cache := filepath.Join(b.mediaDir, fmt.Sprintf("%d.m4a", seq))
	data, err := os.ReadFile(cache)
	if err != nil {
		ogg, err := b.cli.Download(r.Context(), dl)
		if err != nil {
			httpErr(w, err, 502)
			return
		}
		data, err = ffmpeg(r.Context(), ogg, "in.ogg", "out.m4a", "-vn", "-ac", "1", "-c:a", "aac", "-b:a", "48k", "-f", "ipod")
		if err != nil {
			httpErr(w, err, 500)
			return
		}
		os.WriteFile(cache, data, 0o600)
	}
	w.Header().Set("Content-Type", "audio/mp4")
	w.Write(data)
}

// apiSendVoice converts the recording (m4a) and sends it as a voice note.
func (b *Bridge) apiSendVoice(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	chatStr := r.URL.Query().Get("chat")
	rec, err := io.ReadAll(io.LimitReader(r.Body, 16<<20))
	if err != nil || len(rec) == 0 || chatStr == "" {
		http.Error(w, "chat and recording needed", http.StatusBadRequest)
		return
	}
	m, err := b.sendVoice(r.Context(), chatStr, rec)
	if err != nil {
		httpErr(w, err, 502)
		return
	}
	writeJSON(w, m)
}

func (b *Bridge) sendVoice(ctx context.Context, chatStr string, rec []byte) (*Message, error) {
	chat, err := parseChat(chatStr)
	if err != nil {
		return nil, err
	}
	ogg, err := ffmpeg(ctx, rec, "in.m4a", "out.ogg", "-vn", "-ac", "1", "-ar", "48000", "-c:a", "libopus", "-b:a", "24k",
		"-application", "voip", "-f", "ogg")
	if err != nil {
		return nil, err
	}
	secs := duration(ctx, ogg, "voice.ogg")
	if secs <= 0 {
		return nil, errors.New("empty recording")
	}
	up, err := b.cli.Upload(ctx, ogg, whatsmeow.MediaAudio)
	if err != nil {
		return nil, err
	}
	msg := &waE2E.Message{AudioMessage: &waE2E.AudioMessage{
		URL:           proto.String(up.URL),
		DirectPath:    proto.String(up.DirectPath),
		MediaKey:      up.MediaKey,
		Mimetype:      proto.String("audio/ogg; codecs=opus"),
		FileEncSHA256: up.FileEncSHA256,
		FileSHA256:    up.FileSHA256,
		FileLength:    proto.Uint64(up.FileLength),
		Seconds:       proto.Uint32(uint32(secs)),
		PTT:           proto.Bool(true),
	}}
	resp, err := b.cli.SendMessage(ctx, chat, msg)
	if err != nil {
		return nil, err
	}
	raw, _ := proto.Marshal(msg)
	m := &Message{
		ID:     resp.ID,
		Chat:   chat.String(),
		Sender: b.cli.Store.GetJID().ToNonAD().String(),
		FromMe: true,
		TS:     unix(resp.Timestamp),
		Kind:   "audio",
		Status: statusSent,
		Secs:   secs,
	}
	if _, err := b.store.AddMessage(m, raw, false); err != nil {
		return nil, err
	}
	b.store.notify()
	return m, nil
}

// backfillSecs adds lengths for voice notes stored by 0.1.
func (b *Bridge) backfillSecs() {
	rows, err := b.store.AudioWithoutLength()
	if err != nil {
		log.Printf("backfill: %v", err)
		return
	}
	for seq, raw := range rows {
		var msg waE2E.Message
		if proto.Unmarshal(raw, &msg) == nil && mediaSeconds(&msg) > 0 {
			b.store.SetSecs(seq, mediaSeconds(&msg))
		}
	}
}

// apiSendImage sends a jpeg (already scaled by the app).
func (b *Bridge) apiSendImage(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	chatStr := r.URL.Query().Get("chat")
	data, err := io.ReadAll(io.LimitReader(r.Body, 16<<20))
	if err != nil || len(data) == 0 || chatStr == "" {
		http.Error(w, "chat and picture needed", http.StatusBadRequest)
		return
	}
	m, err := b.sendImage(r.Context(), chatStr, data, r.URL.Query().Get("caption"), r.URL.Query().Get("quote"))
	if err != nil {
		httpErr(w, err, 502)
		return
	}
	writeJSON(w, m)
}

func (b *Bridge) sendImage(ctx context.Context, chatStr string, data []byte, caption, quoteID string) (*Message, error) {
	chat, err := parseChat(chatStr)
	if err != nil {
		return nil, err
	}
	img, err := jpeg.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("not a JPEG: %w", err)
	}
	thumb, err := thumbnail(img, 72)
	if err != nil {
		return nil, err
	}
	up, err := b.cli.Upload(ctx, data, whatsmeow.MediaImage)
	if err != nil {
		return nil, err
	}
	size := img.Bounds().Size()
	msg := &waE2E.Message{ImageMessage: &waE2E.ImageMessage{
		URL:           proto.String(up.URL),
		DirectPath:    proto.String(up.DirectPath),
		MediaKey:      up.MediaKey,
		Mimetype:      proto.String("image/jpeg"),
		FileEncSHA256: up.FileEncSHA256,
		FileSHA256:    up.FileSHA256,
		FileLength:    proto.Uint64(up.FileLength),
		Width:         proto.Uint32(uint32(size.X)),
		Height:        proto.Uint32(uint32(size.Y)),
		JPEGThumbnail: thumb,
	}}
	if caption != "" {
		msg.ImageMessage.Caption = proto.String(caption)
	}
	ci, quote := b.replyTo(chat, quoteID)
	msg.ImageMessage.ContextInfo = ci
	resp, err := b.cli.SendMessage(ctx, chat, msg)
	if err != nil {
		return nil, err
	}
	raw, _ := proto.Marshal(msg)
	m := &Message{
		ID:     resp.ID,
		Chat:   chat.String(),
		Sender: b.cli.Store.GetJID().ToNonAD().String(),
		FromMe: true,
		TS:     unix(resp.Timestamp),
		Kind:   "image",
		Text:   caption,
		Status: statusSent,
		Quote:  quote,
	}
	if _, err := b.store.AddMessage(m, raw, false); err != nil {
		return nil, err
	}
	b.store.notify()
	return m, nil
}

// thumbnail makes the small preview.
func thumbnail(img image.Image, maxSide int) ([]byte, error) {
	s := img.Bounds().Size()
	w, h := maxSide, maxSide
	if s.X > s.Y {
		h = max(1, s.Y*maxSide/s.X)
	} else {
		w = max(1, s.X*maxSide/s.Y)
	}
	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	draw.ApproxBiLinear.Scale(dst, dst.Bounds(), img, img.Bounds(), draw.Src, nil)
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, dst, &jpeg.Options{Quality: 60}); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
