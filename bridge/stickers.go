package main

import (
	"bytes"
	"image"
	"image/png"

	"github.com/polymorfa/hypermeow/proto/waE2E"
	imagedraw "golang.org/x/image/draw"
)

const stickerThumbnailMaxSide = 96

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
// phone's 128-point sticker view. Returning nil for invalid data lets the app
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
