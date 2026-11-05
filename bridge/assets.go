package main

import (
	"archive/zip"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// WhatsApp's graphics/sounds aren't shipped with WA Classic. The user lets the bridge download the old
// IPAs from archive.org once (setup page), we keep the files the app needs and serve them
// (the phone can't do modern TLS). Two looks:
// - classic: 2.10.2 (iOS 4-6), data/assets. iOS 7+ uses its sounds too
// - flat: 2.18.81 (last for iOS 7), data/assets-flat. Assets.car, icon font, wallpaper

const assetsPrefix = "Payload/WhatsApp.app/"

type assetLook struct {
	name, version, url, md5 string
	rev                     int // bump when the file list changes
	dir                     string
	minFiles                int
	wanted                  func(zipName string) string
}

var (
	classicLook = assetLook{name: "classic", version: "2.10.2", dir: "assets", minFiles: 100, wanted: wantedAsset,
		url: "https://archive.org/download/whats-app-2.16.2/WhatsApp%202.10.2.ipa", md5: "9d0664cbd61988aa2039d23ebf41a36a"}
	// archive.org only has 2.18.81 with Watusi, whatsapp's files are untouched (2.18.90 needs iOS 8)
	flatLook = assetLook{name: "flat", version: "2.18.81", rev: 2, dir: "assets-flat", minFiles: 4, wanted: wantedFlatAsset,
		url: "https://archive.org/download/WatusiV2.18.81./Watusi-v2.18.81..ipa", md5: "761616b8302fcc3c20145a65f8e6aa44"}
)

// assetNames lists the pics the app uses (.png and @2x). Same list as install-assets.sh, no icon.
var assetNames = map[string]bool{}

func init() {
	for _, n := range strings.Fields(`GreenBubbleOut GrayBubbleIn mark_s mark_d GrayClockIcon ChatInputControlsBG
		ChatInputFieldBG SendButtonNormal SendButtonPressed ChatButtonNormal ChatButtonPressed MicBtn MicRecBtn MicRecRed
		MicRecGray MicOverlay Play PlayPressed Pause PausePressed UIScrubberKnob UIScrubberBlueFill UIScrubberBlueCap
		UIScrubberWhiteFill UIScrubberWhiteCap MicIncoming MicOutgoing MicBlueIncoming MicBlueSent MicChats MicChatsBlue
		EmptyContact GroupChat ThumbMask ThumbOverlay MuteIndicator Chats Settings NotificationBg
		NotificationBgSelected NotificationClose Poof Pen ArrowDown VideoOverlayPlay Download DownloadButtonBg CellDivider
		NoGroupMedia ProfilePicEditPhoto RedButton RedButtonPressed GroupIconFrameEdit TextFieldBg ProfilePicAddPhoto
		BoxShadow PayNowBtn NoFaves TT-LeftTop TT-CenterTop TT-RightTop TT-LeftMiddle TT-CenterMiddle TT-RightMiddle
		TT-LeftBottom TT-CenterBottom TT-ArrowBottom TT-RightBottom TT-Close BrdtChatListIcon BroadcastStatusIcon
		BrdtRebroadcast BroadcastBubbleOut BrdtCheck BrdtDoubleCheck BrdtAttachPanel BrdtAttachCamera
		BrdtAttachCameraPressed BrdtAttachGallery BrdtAttachGalleryPressed BrdtAttachedOverlay BrdtAttachmentRemove
		Default Default-568h`) {
		assetNames[n] = true
	}
	assetNames["My status"] = true
}

// manifestID changes when we keep fewer files, so it downloads again
func (l assetLook) manifestID() string {
	if l.rev == 0 {
		return l.version
	}
	return fmt.Sprintf("%s+%d", l.version, l.rev)
}

// wantedAsset returns the name inside the app folder, "" if unused.
func wantedAsset(zipName string) string {
	name, ok := strings.CutPrefix(zipName, assetsPrefix)
	if !ok || name == "" || strings.HasSuffix(name, "/") {
		return ""
	}
	dir, file := path.Split(name)
	switch {
	case dir == "Wallpaper/" && (strings.HasSuffix(file, ".png") || strings.HasSuffix(file, ".jpg")):
		return name // wallpaper library
	case dir != "":
		return ""
	case strings.HasSuffix(file, ".caf"), file == "PaymentWP@2x.jpg": // sounds + welcome wallpaper
		return name
	case strings.HasSuffix(file, ".png"):
		base := strings.TrimSuffix(strings.TrimSuffix(file, ".png"), "@2x")
		if assetNames[base] {
			return name
		}
	}
	return ""
}

// wantedFlatAsset, same for 2.18.81 (mostly Assets.car).
func wantedFlatAsset(zipName string) string {
	name, ok := strings.CutPrefix(zipName, assetsPrefix)
	if !ok {
		return ""
	}
	switch name {
	case "Assets.car", "WhatsAppIcons.ttf", "Wallpaper/wp_132.jpg", "LaunchImage-700@2x.png", "LaunchImage-700-568h@2x.png",
		"call_overlay.jpg": // call screen bg
		return name
	}
	return ""
}

type assetFile struct {
	Name string `json:"name"`
	Size int64  `json:"size"`
}

type assetManifest struct {
	Version string      `json:"version"`
	Files   []assetFile `json:"files"`
}

type Assets struct {
	look assetLook
	dir  string

	mu          sync.Mutex
	state       string // missing / downloading / ready / failed
	done, total int64  // bytes
	err         string
	manifest    assetManifest
	byName      map[string]bool
}

func newAssets(dataDir string, look assetLook) *Assets {
	a := &Assets{look: look, dir: filepath.Join(dataDir, look.dir), state: "missing"}
	if data, err := os.ReadFile(filepath.Join(a.dir, "manifest.json")); err == nil {
		var m assetManifest
		if json.Unmarshal(data, &m) == nil && m.Version == look.manifestID() {
			a.setManifest(m)
		}
	}
	return a
}

func (a *Assets) setManifest(m assetManifest) {
	a.manifest, a.state, a.err = m, "ready", ""
	a.byName = map[string]bool{}
	for _, f := range m.Files {
		a.byName[f.Name] = true
	}
}

// status for the setup page
func (a *Assets) status() map[string]any {
	a.mu.Lock()
	defer a.mu.Unlock()
	return map[string]any{"state": a.state, "done": a.done, "total": a.total, "error": a.err, "files": len(a.manifest.Files)}
}

// fetch starts the download in the background (one at a time, retries after failure).
func (a *Assets) fetch() {
	a.mu.Lock()
	if a.state == "downloading" || a.state == "ready" {
		a.mu.Unlock()
		return
	}
	a.state, a.done, a.total, a.err = "downloading", 0, 0, ""
	a.mu.Unlock()
	go func() {
		m, err := a.download()
		a.mu.Lock()
		defer a.mu.Unlock()
		if err != nil {
			log.Printf("%s look: %v", a.look.name, err)
			a.state, a.err = "failed", err.Error()
			return
		}
		log.Printf("%s look: %d files of WhatsApp %s ready", a.look.name, len(m.Files), a.look.version)
		a.setManifest(m)
	}()
}

func (a *Assets) download() (assetManifest, error) {
	var m assetManifest
	parent := filepath.Dir(a.dir)
	ipa, err := os.CreateTemp(parent, "whatsapp-*.ipa")
	if err != nil {
		return m, err
	}
	defer os.Remove(ipa.Name())
	defer ipa.Close()

	client := &http.Client{Timeout: 15 * time.Minute}
	resp, err := client.Get(a.look.url)
	if err != nil {
		return m, fmt.Errorf("archive.org can't be reached: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return m, fmt.Errorf("archive.org answered %s", resp.Status)
	}
	a.mu.Lock()
	a.total = resp.ContentLength
	a.mu.Unlock()
	sum := md5.New()
	buf := make([]byte, 64<<10)
	for {
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			sum.Write(buf[:n])
			if _, err := ipa.Write(buf[:n]); err != nil {
				return m, err
			}
			a.mu.Lock()
			a.done += int64(n)
			a.mu.Unlock()
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return m, fmt.Errorf("download broke off: %w", rerr)
		}
	}
	if got := hex.EncodeToString(sum.Sum(nil)); got != a.look.md5 {
		return m, fmt.Errorf("the downloaded file is not the expected WhatsApp %s (checksum differs)", a.look.version)
	}

	zr, err := zip.OpenReader(ipa.Name())
	if err != nil {
		return m, err
	}
	defer zr.Close()
	stage, err := os.MkdirTemp(parent, "assets-new-")
	if err != nil {
		return m, err
	}
	defer os.RemoveAll(stage)
	m.Version = a.look.manifestID()
	for _, f := range zr.File {
		name := a.look.wanted(f.Name)
		if name == "" {
			continue
		}
		size, err := extractTo(f, filepath.Join(stage, filepath.FromSlash(name)))
		if err != nil {
			return m, err
		}
		m.Files = append(m.Files, assetFile{Name: name, Size: size})
	}
	if len(m.Files) < a.look.minFiles {
		return m, fmt.Errorf("only %d files found in the app", len(m.Files))
	}
	data, _ := json.MarshalIndent(m, "", "  ")
	if err := os.WriteFile(filepath.Join(stage, "manifest.json"), data, 0o600); err != nil {
		return m, err
	}
	os.RemoveAll(a.dir)
	return m, os.Rename(stage, a.dir)
}

func extractTo(f *zip.File, dst string) (int64, error) {
	if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
		return 0, err
	}
	rc, err := f.Open()
	if err != nil {
		return 0, err
	}
	defer rc.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return 0, err
	}
	n, err := io.Copy(out, io.LimitReader(rc, 32<<20)) // ~7.9 MB
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	return n, err
}

// apiList: GET /api/assets[?look=flat]
func (a *Assets) apiList(w http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	out := map[string]any{"version": a.look.version, "look": a.look.name, "state": a.state}
	if a.state == "ready" {
		out["files"] = a.manifest.Files
	}
	a.mu.Unlock()
	writeJSON(w, out)
}

// apiFile: GET /api/assets/file?name=...[&look=flat], manifest names only.
func (a *Assets) apiFile(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("name")
	a.mu.Lock()
	ok := a.state == "ready" && a.byName[name]
	a.mu.Unlock()
	if !ok {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	http.ServeFile(w, r, filepath.Join(a.dir, filepath.FromSlash(name)))
}

// AssetLooks holds both, app asks for its own (flat on iOS 7+).
type AssetLooks struct{ classic, flat *Assets }

func newAssetLooks(dataDir string) *AssetLooks {
	return &AssetLooks{classic: newAssets(dataDir, classicLook), flat: newAssets(dataDir, flatLook)}
}

func (l *AssetLooks) pick(r *http.Request) *Assets {
	if r.URL.Query().Get("look") == "flat" {
		return l.flat
	}
	return l.classic
}

// only classic for now, flat comes back with the ios 7 version
func (l *AssetLooks) fetch() {
	l.classic.fetch()
}

// status: classic with flat inside
func (l *AssetLooks) status() map[string]any {
	out := l.classic.status()
	out["flat"] = l.flat.status()
	return out
}

func (l *AssetLooks) apiList(w http.ResponseWriter, r *http.Request) { l.pick(r).apiList(w, r) }
func (l *AssetLooks) apiFile(w http.ResponseWriter, r *http.Request) { l.pick(r).apiFile(w, r) }
