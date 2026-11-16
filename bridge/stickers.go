package main

import (
	"bytes"
	"context"
	"fmt"
	"image"
	"image/gif"
	"image/png"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/polymorfa/hypermeow/proto/waE2E"
	imagedraw "golang.org/x/image/draw"
)

const stickerThumbnailMaxSide = 70

const stickerDownloadMaxSize = 4 << 20

// mediaThumbnail returns a thumbnail already embedded in the message. Sticker
// previews are reduced before being sent to the phone and never fetch the WebP.
func mediaThumbnail(msg *waE2E.Message) ([]byte, string) {
	switch {
	case msg.GetStickerMessage() != nil:
		return smallStickerThumbnail(msg.GetStickerMessage().GetPngThumbnail()), "image/png"
	case msg.GetImageMessage() != nil:
		return msg.GetImageMessage().GetJPEGThumbnail(), "image/jpeg"
	case msg.GetVideoMessage() != nil:
		return msg.GetVideoMessage().GetJPEGThumbnail(), "image/jpeg"
	default:
		return nil, ""
	}
}

// smallStickerThumbnail keeps the transparent embedded PNG small for the
// phone's 70-pixel sticker preview. Returning nil for invalid data lets the app
// show its lightweight placeholder instead of fetching the original sticker.
func smallStickerThumbnail(data []byte) []byte {
	if len(data) == 0 {
		return nil
	}
	img, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		return nil
	}
	bounds := img.Bounds()
	w, h := bounds.Dx(), bounds.Dy()
	if w <= 0 || h <= 0 || w > 1024 || h > 1024 {
		return nil
	}
	if w <= stickerThumbnailMaxSide && h <= stickerThumbnailMaxSide {
		return data
	}

	scale := float64(stickerThumbnailMaxSide) / float64(max(w, h))
	dstW := max(1, int(float64(w)*scale+0.5))
	dstH := max(1, int(float64(h)*scale+0.5))
	small := image.NewNRGBA(image.Rect(0, 0, dstW, dstH))
	imagedraw.ApproxBiLinear.Scale(small, small.Bounds(), img, bounds, imagedraw.Src, nil)

	var out bytes.Buffer
	if err := png.Encode(&out, small); err != nil {
		return nil
	}
	return out.Bytes()
}

// stickerThumbnail returns the embedded preview when present. Some messages
// omit PngThumbnail, so fetch the WebP on the bridge, render one small frame,
// and cache only that PNG. The iPhone never receives the original sticker.
func (b *Bridge) stickerThumbnail(ctx context.Context, seq int64, sticker *waE2E.StickerMessage) ([]byte, error) {
	cache := filepath.Join(b.mediaDir, fmt.Sprintf("%d.sticker.png", seq))
	unlock := lockFor(cache)
	defer unlock()

	if data, err := os.ReadFile(cache); err == nil {
		if _, err := png.DecodeConfig(bytes.NewReader(data)); err == nil {
			return data, nil
		}
		_ = os.Remove(cache)
	}

	if data := smallStickerThumbnail(sticker.GetPngThumbnail()); len(data) > 0 {
		if err := os.WriteFile(cache, data, 0o600); err == nil {
			return data, nil
		}
		return data, nil
	}
	if sticker.GetFileLength() > stickerDownloadMaxSize {
		return nil, fmt.Errorf("sticker is too large to make a preview: %d bytes", sticker.GetFileLength())
	}

	original, err := b.cli.Download(ctx, sticker)
	if err != nil {
		return nil, fmt.Errorf("download sticker for preview: %w", err)
	}
	if len(original) > stickerDownloadMaxSize {
		return nil, fmt.Errorf("sticker is too large to make a preview: %d bytes", len(original))
	}
	frame, err := firstWebPFrame(ctx, original)
	if err != nil {
		return nil, fmt.Errorf("extract sticker frame: %w", err)
	}
	data, err := ffmpeg(ctx, frame, "sticker.webp", "preview.png",
		"-vf", fmt.Sprintf("scale=%d:%d:force_original_aspect_ratio=decrease,format=rgba", stickerThumbnailMaxSide, stickerThumbnailMaxSide),
		"-frames:v", "1", "-c:v", "png", "-f", "image2")
	if err != nil {
		return nil, fmt.Errorf("render sticker preview: %w", err)
	}
	config, err := png.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("invalid sticker preview PNG: %w", err)
	}
	if config.Width > stickerThumbnailMaxSide || config.Height > stickerThumbnailMaxSide {
		return nil, fmt.Errorf("sticker preview is oversized: %dx%d", config.Width, config.Height)
	}
	if err := os.WriteFile(cache, data, 0o600); err != nil {
		return data, nil
	}
	return data, nil
}

// stickerAnimation converts an animated WebP into a small, transparent GIF.
// It preserves the animation's frames and timing while resizing to the same
// 70-pixel preview used by the app. The cached GIF is the only animated asset
// sent to the phone; the original WebP stays on the bridge.
func (b *Bridge) stickerAnimation(ctx context.Context, seq int64, sticker *waE2E.StickerMessage) ([]byte, error) {
	if sticker == nil || !sticker.GetIsAnimated() {
		return nil, fmt.Errorf("sticker is not animated")
	}
	cache := filepath.Join(b.mediaDir, fmt.Sprintf("%d.sticker.gif", seq))
	unlock := lockFor(cache)
	defer unlock()

	if data, err := os.ReadFile(cache); err == nil {
		if config, err := gif.DecodeConfig(bytes.NewReader(data)); err == nil && config.Width > 0 && config.Height > 0 {
			return data, nil
		}
		_ = os.Remove(cache)
	}

	original, err := b.cli.Download(ctx, sticker)
	if err != nil {
		return nil, fmt.Errorf("download animated sticker: %w", err)
	}
	filter := "[0:v]scale=70:70:force_original_aspect_ratio=decrease:flags=lanczos,pad=70:70:(ow-iw)/2:(oh-ih)/2:color=black@0,split[base][diff];[base]palettegen=stats_mode=diff:max_colors=128:reserve_transparent=1[palette];[diff][palette]paletteuse=dither=bayer:diff_mode=rectangle[gif]"
	data, err := ffmpeg(ctx, original, "sticker.webp", "sticker.gif",
		"-filter_complex", filter, "-map", "[gif]", "-loop", "0", "-gifflags", "+offsetting+transdiff", "-an", "-f", "gif")
	if err != nil {
		return nil, fmt.Errorf("convert animated sticker to GIF: %w", err)
	}
	config, err := gif.DecodeConfig(bytes.NewReader(data))
	if err != nil || config.Width > stickerThumbnailMaxSide || config.Height > stickerThumbnailMaxSide {
		return nil, fmt.Errorf("invalid animated sticker GIF")
	}
	if err := os.WriteFile(cache, data, 0o600); err != nil {
		return data, nil
	}
	return data, nil
}

// firstWebPFrame extracts an animation's first frame. For a static WebP,
// webpmux returns an error and the original remains suitable for ffmpeg.
func firstWebPFrame(ctx context.Context, data []byte) ([]byte, error) {
	dir, err := os.MkdirTemp("", "wa4s-sticker-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	inPath := filepath.Join(dir, "input.webp")
	outPath := filepath.Join(dir, "frame.webp")
	if err := os.WriteFile(inPath, data, 0o600); err != nil {
		return nil, err
	}
	cmdCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if err := exec.CommandContext(cmdCtx, "webpmux", "-get", "frame", "1", inPath, "-o", outPath).Run(); err != nil {
		return data, nil
	}
	frame, err := os.ReadFile(outPath)
	if err != nil {
		return nil, err
	}
	return frame, nil
}
