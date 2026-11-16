package main

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"net/http/httptest"
	"testing"

	"github.com/polymorfa/hypermeow/proto/waE2E"
	"google.golang.org/protobuf/proto"
)

func testStickerPNG(t *testing.T, width, height int) []byte {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, width, height))
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			img.SetNRGBA(x, y, color.NRGBA{
				R: uint8(x), G: uint8(y), B: uint8(x * y), A: 96,
			})
		}
	}
	var out bytes.Buffer
	if err := png.Encode(&out, img); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

func TestStickerThumbnailServedWithoutDownloadingOriginal(t *testing.T) {
	thumbnail := testStickerPNG(t, 48, 48)
	raw, err := proto.Marshal(&waE2E.Message{StickerMessage: &waE2E.StickerMessage{
		PngThumbnail: thumbnail,
	}})
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest("GET", "/api/media?seq=1&format=thumb", nil)
	res := httptest.NewRecorder()
	(&Bridge{mediaDir: t.TempDir()}).serveRaw(res, req, 1, raw)

	if res.Code != 200 {
		t.Fatalf("status = %d, want 200: %s", res.Code, res.Body.String())
	}
	if got := res.Header().Get("Content-Type"); got != "image/png" {
		t.Fatalf("Content-Type = %q, want image/png", got)
	}
	if !bytes.Equal(res.Body.Bytes(), thumbnail) {
		t.Fatal("small embedded thumbnail should be returned without conversion")
	}
}

func TestStickerThumbnailIsReducedAndKeepsTransparency(t *testing.T) {
	thumbnail := testStickerPNG(t, 192, 128)
	small := smallStickerThumbnail(thumbnail)
	if len(small) == 0 {
		t.Fatal("expected a resized PNG thumbnail")
	}
	if len(small) >= len(thumbnail) {
		t.Fatalf("resized PNG is %d bytes, original thumbnail is %d bytes", len(small), len(thumbnail))
	}

	img, err := png.Decode(bytes.NewReader(small))
	if err != nil {
		t.Fatal(err)
	}
	bounds := img.Bounds()
	if max(bounds.Dx(), bounds.Dy()) > stickerThumbnailMaxSide {
		t.Fatalf("resized dimensions are %dx%d, want maximum side %d", bounds.Dx(), bounds.Dy(), stickerThumbnailMaxSide)
	}
	_, _, _, alpha := img.At(bounds.Dx()/2, bounds.Dy()/2).RGBA()
	if alpha != 96*0x101 {
		t.Fatalf("resized alpha = %d, want %d", alpha, 96*0x101)
	}
}

func TestStickerWithoutThumbnailReturnsNotFound(t *testing.T) {
	raw, err := proto.Marshal(&waE2E.Message{StickerMessage: &waE2E.StickerMessage{}})
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest("GET", "/api/media?seq=1&format=thumb", nil)
	res := httptest.NewRecorder()
	(&Bridge{mediaDir: t.TempDir()}).serveRaw(res, req, 1, raw)

	if res.Code != 404 {
		t.Fatalf("status = %d, want 404", res.Code)
	}
}
