package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWantedAsset(t *testing.T) {
	for in, want := range map[string]string{
		"Payload/WhatsApp.app/Chats@2x.png":                 "Chats@2x.png",
		"Payload/WhatsApp.app/My status.png":                "My status.png",
		"Payload/WhatsApp.app/mark_d@2x.png":                "mark_d@2x.png",
		"Payload/WhatsApp.app/Tri-tone.caf":                 "Tri-tone.caf",
		"Payload/WhatsApp.app/PaymentWP@2x.jpg":             "PaymentWP@2x.jpg",
		"Payload/WhatsApp.app/Wallpaper/wallpaper_01.png":   "Wallpaper/wallpaper_01.png",
		"Payload/WhatsApp.app/Icon@2x.png":                  "",
		"Payload/WhatsApp.app/WhatsApp":                     "",
		"Payload/WhatsApp.app/en.lproj/Localizable.strings": "",
		"Payload/WhatsApp.app/Wallpaper/../../x.png":        "",
		"Payload/WhatsApp.app/Wallpaper/":                   "",
		"iTunesArtwork":                                     "",
	} {
		if got := wantedAsset(in); got != want {
			t.Errorf("wantedAsset(%q) = %q, want %q", in, got, want)
		}
	}
}

// WA4S_NET=1 go test -run TestAssetsDownload -v (downloads the real IPA)
func TestAssetsDownload(t *testing.T) {
	if os.Getenv("WA4S_NET") != "1" {
		t.Skip("needs the network (WA4S_NET=1)")
	}
	a := newAssets(t.TempDir(), classicLook)
	m, err := a.download()
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("%d files", len(m.Files))
	for _, want := range []string{"GreenBubbleOut@2x.png", "My status@2x.png", "Tri-tone.caf", "Default-568h@2x.png", "Wallpaper/wallpaper_01.png"} {
		if _, err := os.Stat(filepath.Join(a.dir, want)); err != nil {
			t.Error(err)
		}
	}
}

func TestWantedFlatAsset(t *testing.T) {
	for in, want := range map[string]string{
		"Payload/WhatsApp.app/Assets.car":                     "Assets.car",
		"Payload/WhatsApp.app/WhatsAppIcons.ttf":              "WhatsAppIcons.ttf",
		"Payload/WhatsApp.app/Wallpaper/wp_132.jpg":           "Wallpaper/wp_132.jpg",
		"Payload/WhatsApp.app/LaunchImage-700-568h@2x.png":    "LaunchImage-700-568h@2x.png",
		"Payload/WhatsApp.app/call_overlay.jpg":               "call_overlay.jpg",
		"Payload/WhatsApp.app/Wallpaper/wp_001.thumb":         "",
		"Payload/WhatsApp.app/Watusi.dylib":                   "",
		"Payload/WhatsApp.app/FRAssets.bundle/Assets.car":     "",
		"Payload/WhatsApp.app/PlugIns/ShareExtension.appex/x": "",
		"Payload/WhatsApp.app/WhatsApp":                       "",
	} {
		if got := wantedFlatAsset(in); got != want {
			t.Errorf("wantedFlatAsset(%q) = %q, want %q", in, got, want)
		}
	}
}

// WA4S_NET=1 go test -run TestFlatAssetsDownload -v (93 MB)
func TestFlatAssetsDownload(t *testing.T) {
	if os.Getenv("WA4S_NET") != "1" {
		t.Skip("needs the network (WA4S_NET=1)")
	}
	a := newAssets(t.TempDir(), flatLook)
	m, err := a.download()
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("%v", m.Files)
	if len(m.Files) != 6 {
		t.Errorf("%d files, want 6", len(m.Files))
	}
}
