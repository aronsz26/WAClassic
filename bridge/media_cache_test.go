package main

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/jpeg"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPruneMediaCacheUsesOldestFirstAndRemovesTemps(t *testing.T) {
	dir := t.TempDir()
	old := filepath.Join(dir, "old.m4a")
	newer := filepath.Join(dir, "new.mp4")
	tmp := filepath.Join(dir, "partial.tmp")
	for path, data := range map[string]string{old: "12345", newer: "67890", tmp: "temporary"} {
		if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	oldTime := time.Now().Add(-time.Hour)
	if err := os.Chtimes(old, oldTime, oldTime); err != nil {
		t.Fatal(err)
	}
	pruneMediaCacheToLocked(dir, 5)
	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Fatalf("oldest file should be evicted, stat err=%v", err)
	}
	if _, err := os.Stat(newer); err != nil {
		t.Fatalf("newer file should remain: %v", err)
	}
	if _, err := os.Stat(tmp); !os.IsNotExist(err) {
		t.Fatalf("partial file should be removed, stat err=%v", err)
	}
}

func TestResizeJPEGBoundsDimensionsAndOutput(t *testing.T) {
	// A tiny generated image exercises the encoder and image format contract.
	in := image.NewRGBA(image.Rect(0, 0, 640, 480))
	for y := 0; y < 480; y++ {
		for x := 0; x < 640; x++ {
			in.Set(x, y, color.RGBA{R: uint8(x), G: uint8(y), A: 255})
		}
	}
	var source bytes.Buffer
	if err := jpeg.Encode(&source, in, &jpeg.Options{Quality: 90}); err != nil {
		t.Fatal(err)
	}
	data, err := resizeJPEG(source.Bytes(), 320, 52)
	if err != nil {
		t.Fatal(err)
	}
	config, err := jpeg.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	if config.Width != 320 || config.Height != 240 {
		t.Fatalf("unexpected dimensions: %dx%d", config.Width, config.Height)
	}
}

func TestOptimizedImageUsesPersistentOriginalAndBoundsOutput(t *testing.T) {
	dir := t.TempDir()
	in := image.NewRGBA(image.Rect(0, 0, 1600, 1200))
	var source bytes.Buffer
	if err := jpeg.Encode(&source, in, &jpeg.Options{Quality: 90}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "42.original"), source.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
	b := &Bridge{mediaDir: dir}
	optimized, err := b.imageFile(context.Background(), 42, nil, true)
	if err != nil {
		t.Fatal(err)
	}
	config, err := jpeg.DecodeConfig(bytes.NewReader(optimized))
	if err != nil {
		t.Fatal(err)
	}
	if config.Width != 960 || config.Height != 720 {
		t.Fatalf("optimized image is %dx%d, want 960x720", config.Width, config.Height)
	}
	if _, err := os.Stat(filepath.Join(dir, "42.optimized.jpg")); err != nil {
		t.Fatalf("optimized variant was not cached: %v", err)
	}
}
