package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image/jpeg"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"

	"github.com/polymorfa/hypermeow"
	"github.com/polymorfa/hypermeow/proto/waE2E"
	"google.golang.org/protobuf/proto"
)

// mediaSeconds returns the length.
func mediaSeconds(msg *waE2E.Message) int {
	switch {
	case msg.GetAudioMessage() != nil:
		return int(msg.GetAudioMessage().GetSeconds())
	case msg.GetVideoMessage() != nil:
		return int(msg.GetVideoMessage().GetSeconds())
	case msg.GetPtvMessage() != nil:
		return int(msg.GetPtvMessage().GetSeconds())
	}
	return 0
}

// one conversion per message at a time
var convertLocks sync.Map

func lockFor(key string) func() {
	m, _ := convertLocks.LoadOrStore(key, &sync.Mutex{})
	mu := m.(*sync.Mutex)
	mu.Lock()
	return mu.Unlock
}

// mp4ForIPhone: h264 main, max 640px, aac, faststart (plays on the 4s).
func mp4ForIPhone(ctx context.Context, in []byte) ([]byte, error) {
	return ffmpeg(ctx, in, "in.mp4", "out.mp4",
		"-vf", "scale='min(640,iw)':-2", "-c:v", "libx264", "-profile:v", "main", "-level", "3.1",
		"-pix_fmt", "yuv420p", "-preset", "veryfast", "-crf", "26",
		"-c:a", "aac", "-b:a", "96k", "-ac", "2", "-movflags", "+faststart", "-f", "mp4")
}

// mp4Optimized: max 480px, baseline 3.0 (works down to the 3gs), mono, ~1/4 size.
func mp4Optimized(ctx context.Context, in []byte) ([]byte, error) {
	return ffmpeg(ctx, in, "in.mp4", "out.mp4",
		"-vf", "scale='min(480,iw)':-2", "-c:v", "libx264", "-profile:v", "baseline", "-level", "3.0",
		"-pix_fmt", "yuv420p", "-preset", "veryfast", "-crf", "30", "-maxrate", "600k", "-bufsize", "1200k",
		"-c:a", "aac", "-b:a", "48k", "-ac", "1", "-movflags", "+faststart", "-f", "mp4")
}

// videoFile returns the converted video (cached).
func (b *Bridge) videoFile(ctx context.Context, seq int64, dl whatsmeow.DownloadableMessage, small bool) (string, error) {
	convert, name := mp4ForIPhone, fmt.Sprintf("%d.mp4", seq)
	if small {
		convert, name = mp4Optimized, fmt.Sprintf("%d.small.mp4", seq)
	}
	path := filepath.Join(b.mediaDir, name)
	unlock := lockFor(path)
	defer unlock()
	if _, err := os.Stat(path); err == nil {
		return path, nil
	}
	orig, err := b.cli.Download(ctx, dl)
	if err != nil {
		return "", err
	}
	mp4, err := convert(ctx, orig)
	if err != nil {
		return "", err
	}
	return path, os.WriteFile(path, mp4, 0o600)
}

// posterFile is the preview frame.
func (b *Bridge) posterFile(ctx context.Context, seq int64, video string) (string, error) {
	path := filepath.Join(b.mediaDir, fmt.Sprintf("%d.jpg", seq))
	if _, err := os.Stat(path); err == nil {
		return path, nil
	}
	data, err := os.ReadFile(video)
	if err != nil {
		return "", err
	}
	frame, err := videoFrame(ctx, data, 400)
	if err != nil {
		return "", err
	}
	return path, os.WriteFile(path, frame, 0o600)
}

// videoFrame grabs a jpeg at 0.5s (or the first frame).
func videoFrame(ctx context.Context, video []byte, width int) ([]byte, error) {
	scale := fmt.Sprintf("scale=%d:-2", width)
	frame, err := ffmpeg(ctx, video, "in.mp4", "frame.jpg", "-ss", "0.5", "-frames:v", "1", "-vf", scale, "-q:v", "4")
	if err != nil || len(frame) == 0 {
		frame, err = ffmpeg(ctx, video, "in.mp4", "frame.jpg", "-frames:v", "1", "-vf", scale, "-q:v", "4")
	}
	return frame, err
}

func (b *Bridge) serveVideo(w http.ResponseWriter, r *http.Request, seq int64, dl whatsmeow.DownloadableMessage, poster bool) {
	// poster from whatever version exists
	small := r.URL.Query().Get("optimize") == "1"
	if poster {
		_, errFull := os.Stat(filepath.Join(b.mediaDir, fmt.Sprintf("%d.mp4", seq)))
		_, errSmall := os.Stat(filepath.Join(b.mediaDir, fmt.Sprintf("%d.small.mp4", seq)))
		small = errFull != nil && (errSmall == nil || small)
	}
	video, err := b.videoFile(r.Context(), seq, dl, small)
	if err != nil {
		httpErr(w, err, 502)
		return
	}
	if poster {
		path, err := b.posterFile(r.Context(), seq, video)
		if err != nil {
			httpErr(w, err, 500)
			return
		}
		w.Header().Set("Content-Type", "image/jpeg")
		http.ServeFile(w, r, path)
		return
	}
	w.Header().Set("Content-Type", "video/mp4")
	http.ServeFile(w, r, video)
}

// apiSendVideo converts the .mov to mp4 and sends it.
func (b *Bridge) apiSendVideo(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	chatStr := r.URL.Query().Get("chat")
	data, err := io.ReadAll(io.LimitReader(r.Body, 100<<20))
	if err != nil || len(data) == 0 || chatStr == "" {
		http.Error(w, "chat and video needed", http.StatusBadRequest)
		return
	}
	m, err := b.sendVideo(r.Context(), chatStr, data, r.URL.Query().Get("quote"))
	if err != nil {
		httpErr(w, err, 502)
		return
	}
	writeJSON(w, m)
}

func (b *Bridge) sendVideo(ctx context.Context, chatStr string, in []byte, quoteID string) (*Message, error) {
	chat, err := parseChat(chatStr)
	if err != nil {
		return nil, err
	}
	mp4, err := mp4ForIPhone(ctx, in)
	if err != nil {
		return nil, err
	}
	secs := duration(ctx, mp4, "video.mp4")
	width, height := videoSize(ctx, mp4)
	frame, err := videoFrame(ctx, mp4, 320)
	if err != nil {
		return nil, err
	}
	img, err := jpeg.Decode(bytes.NewReader(frame))
	if err != nil {
		return nil, err
	}
	thumb, err := thumbnail(img, 72)
	if err != nil {
		return nil, err
	}
	up, err := b.cli.Upload(ctx, mp4, whatsmeow.MediaVideo)
	if err != nil {
		return nil, err
	}
	msg := &waE2E.Message{VideoMessage: &waE2E.VideoMessage{
		URL:           proto.String(up.URL),
		DirectPath:    proto.String(up.DirectPath),
		MediaKey:      up.MediaKey,
		Mimetype:      proto.String("video/mp4"),
		FileEncSHA256: up.FileEncSHA256,
		FileSHA256:    up.FileSHA256,
		FileLength:    proto.Uint64(up.FileLength),
		Seconds:       proto.Uint32(uint32(secs)),
		Width:         proto.Uint32(uint32(width)),
		Height:        proto.Uint32(uint32(height)),
		JPEGThumbnail: thumb,
	}}
	ci, quote := b.replyTo(chat, quoteID)
	msg.VideoMessage.ContextInfo = ci
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
		Kind:   "video",
		Status: statusSent,
		Secs:   secs,
		Quote:  quote,
	}
	if _, err := b.store.AddMessage(m, raw, false); err != nil {
		return nil, err
	}
	if m.Seq > 0 {
		// no need to download our own video again
		os.WriteFile(filepath.Join(b.mediaDir, fmt.Sprintf("%d.mp4", m.Seq)), mp4, 0o600)
	}
	b.store.notify()
	return m, nil
}

func videoSize(ctx context.Context, data []byte) (int, int) {
	dir, err := os.MkdirTemp("", "wa4s-")
	if err != nil {
		return 0, 0
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "v.mp4")
	if os.WriteFile(path, data, 0o600) != nil {
		return 0, 0
	}
	out, err := exec.CommandContext(ctx, "ffprobe", "-v", "error", "-select_streams", "v:0",
		"-show_entries", "stream=width,height", "-of", "csv=p=0", path).Output()
	if err != nil {
		return 0, 0
	}
	parts := strings.Split(strings.TrimSpace(string(out)), ",")
	if len(parts) != 2 {
		return 0, 0
	}
	w, _ := strconv.Atoi(parts[0])
	h, _ := strconv.Atoi(parts[1])
	return w, h
}

var errNotVideo = errors.New("not a video")
