package main

import (
	"bytes"
	"context"
	"image"
	"image/jpeg"
	_ "image/png"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/polymorfa/hypermeow/appstate"
	"github.com/polymorfa/hypermeow/types"
	"github.com/polymorfa/hypermeow/types/events"
	"golang.org/x/image/draw"
)

// Own profile, contacts, last seen, blocklist.

func (b *Bridge) ownJID() types.JID {
	if id := b.cli.Store.ID; id != nil {
		return id.ToNonAD()
	}
	return types.EmptyJID
}

// apiMe: number, name, about, link info.
func (b *Bridge) apiMe(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	own := b.ownJID()
	if own.IsEmpty() {
		http.Error(w, "not linked", http.StatusConflict)
		return
	}
	out := map[string]any{"jid": own.String(), "phone": phoneNumber(own), "pushName": b.cli.Store.PushName,
		"device": b.cli.Store.ID.Device, "connected": b.cli.IsConnected(), "platform": "WA4S (linked device)"}
	if infos, err := b.cli.GetUserInfo(ctx, []types.JID{own}); err == nil {
		for _, info := range infos {
			out["about"] = info.Status
		}
	}
	if s, err := b.cli.TryFetchPrivacySettings(ctx, false); err == nil {
		out["lastSeen"] = string(s.LastSeen)
		out["readReceipts"] = string(s.ReadReceipts)
	}
	writeJSON(w, out)
}

// apiSetName sets the push name.
func (b *Bridge) apiSetName(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimSpace(r.FormValue("name"))
	if name == "" || len([]rune(name)) > 25 {
		http.Error(w, "1 to 25 characters", http.StatusBadRequest)
		return
	}
	if name == b.cli.Store.PushName {
		writeJSON(w, map[string]any{"pushName": name})
		return
	}
	err := b.cli.SendAppState(r.Context(), appstate.BuildSettingPushName(name))
	if err != nil {
		// after a fresh pair critical_block can fail with a bad LTHash, a full resync fixes it
		log.Printf("set name: %v, resyncing critical_block", err)
		if err = b.cli.FetchAppState(r.Context(), appstate.WAPatchCriticalBlock, true, false); err == nil {
			err = b.cli.SendAppState(r.Context(), appstate.BuildSettingPushName(name))
		}
	}
	if err != nil {
		log.Printf("set name: %v", err)
		httpErr(w, err, 502)
		return
	}
	b.cli.Store.PushName = name
	b.cli.Store.Save(r.Context())
	writeJSON(w, map[string]any{"pushName": name})
}

// apiSetAbout sets the about text.
func (b *Bridge) apiSetAbout(w http.ResponseWriter, r *http.Request) {
	text := strings.TrimSpace(r.FormValue("about"))
	if len([]rune(text)) > 139 {
		http.Error(w, "at most 139 characters", http.StatusBadRequest)
		return
	}
	if err := b.cli.SetStatusMessage(r.Context(), types.SetStatusInput{Text: &text}); err != nil {
		httpErr(w, err, 502)
		return
	}
	writeJSON(w, map[string]any{"about": text})
}

// apiSetPhoto sets the profile pic (cropped to 640px square), empty body removes it.
func (b *Bridge) apiSetPhoto(w http.ResponseWriter, r *http.Request) {
	data, err := io.ReadAll(io.LimitReader(r.Body, 10<<20))
	if err != nil {
		httpErr(w, err, 400)
		return
	}
	var avatar []byte
	if len(data) > 0 {
		img, _, err := image.Decode(bytes.NewReader(data))
		if err != nil {
			httpErr(w, err, 400)
			return
		}
		avatar, err = squareJPEG(img, 640)
		if err != nil {
			httpErr(w, err, 500)
			return
		}
	}
	// no target = own pic
	if _, err := b.cli.SetGroupPhoto(r.Context(), types.EmptyJID, avatar); err != nil {
		httpErr(w, err, 502)
		return
	}
	b.forgetAvatar(b.ownJID())
	writeJSON(w, map[string]any{"ok": true})
}

// forgetAvatar drops cached avatars for jid.
func (b *Bridge) forgetAvatar(jid types.JID) {
	name := strings.NewReplacer("@", "_", ":", "_", "/", "_").Replace(jid.String())
	for _, f := range []string{name + ".jpg", name + ".none", name + "_full.jpg", name + "_full.none"} {
		os.Remove(filepath.Join(b.avatarDir, f))
	}
}

func squareJPEG(img image.Image, size int) ([]byte, error) {
	bnd := img.Bounds()
	side := min(bnd.Dx(), bnd.Dy())
	crop := image.Rect(bnd.Min.X+(bnd.Dx()-side)/2, bnd.Min.Y+(bnd.Dy()-side)/2, 0, 0)
	crop.Max = crop.Min.Add(image.Pt(side, side))
	dst := image.NewRGBA(image.Rect(0, 0, size, size))
	draw.CatmullRom.Scale(dst, dst.Bounds(), img, crop, draw.Src, nil)
	var buf bytes.Buffer
	err := jpeg.Encode(&buf, dst, &jpeg.Options{Quality: 85})
	return buf.Bytes(), err
}

// apiSetLastSeen: all / contacts / contact_blacklist / none.
func (b *Bridge) apiSetLastSeen(w http.ResponseWriter, r *http.Request) {
	v := types.PrivacySetting(r.FormValue("value"))
	if v != types.PrivacySettingAll && v != types.PrivacySettingContacts && v != types.PrivacySettingContactBlacklist && v != types.PrivacySettingNone {
		http.Error(w, "all, contacts, contact_blacklist or none", http.StatusBadRequest)
		return
	}
	s, err := b.cli.SetPrivacySetting(r.Context(), types.PrivacySettingTypeLastSeen, v)
	if err != nil {
		httpErr(w, err, 502)
		return
	}
	writeJSON(w, map[string]any{"lastSeen": string(s.LastSeen)})
}

// contact is a row in the contacts tab.
type contact struct {
	JID   string `json:"jid"`
	Name  string `json:"name"`
	Phone string `json:"phone"`
	About string `json:"about,omitempty"`
}

// about texts, fetched in batches, cached
var aboutCache struct {
	sync.Mutex
	texts map[string]string
	at    time.Time
}

func (b *Bridge) contactAbouts(ctx context.Context, jids []types.JID) map[string]string {
	aboutCache.Lock()
	defer aboutCache.Unlock()
	if aboutCache.texts != nil && time.Since(aboutCache.at) < 6*time.Hour && len(aboutCache.texts) >= len(jids)/2 {
		return aboutCache.texts
	}
	texts := map[string]string{}
	for start := 0; start < len(jids); start += 100 {
		end := min(start+100, len(jids))
		infos, err := b.cli.GetUserInfo(ctx, jids[start:end])
		if err != nil {
			continue
		}
		for jid, info := range infos {
			texts[b.chatKey(ctx, jid).String()] = info.Status
		}
	}
	aboutCache.texts, aboutCache.at = texts, time.Now()
	return texts
}

// apiContacts lists address book contacts on whatsapp, A-Z.
func (b *Bridge) apiContacts(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	all, err := b.cli.Store.Contacts.GetAllContacts(ctx)
	if err != nil {
		httpErr(w, err, 500)
		return
	}
	own := b.ownJID()
	seen := map[string]bool{}
	var list []contact
	var jids []types.JID
	for jid, info := range all {
		if info.FullName == "" && info.FirstName == "" { // not in address book
			continue
		}
		key := b.chatKey(ctx, jid)
		if key.Server != types.DefaultUserServer || key == own || seen[key.String()] {
			continue
		}
		seen[key.String()] = true
		name := info.FullName
		if name == "" {
			name = info.FirstName
		}
		list = append(list, contact{JID: key.String(), Name: name, Phone: phoneNumber(key)})
		jids = append(jids, key)
	}
	if r.URL.Query().Get("about") != "0" {
		abouts := b.contactAbouts(ctx, jids)
		for i := range list {
			list[i].About = abouts[list[i].JID]
		}
	}
	sort.Slice(list, func(i, j int) bool { return strings.ToLower(list[i].Name) < strings.ToLower(list[j].Name) })
	if list == nil {
		list = []contact{}
	}
	writeJSON(w, map[string]any{"contacts": list, "me": phoneNumber(own)})
}

// apiBlocklist: GET list, POST jid + action=block|unblock.
func (b *Bridge) apiBlocklist(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	var list *types.Blocklist
	var err error
	if r.Method == http.MethodPost {
		jid, perr := parseChat(r.FormValue("jid"))
		if perr != nil {
			httpErr(w, perr, 400)
			return
		}
		action := events.BlocklistChangeActionBlock
		if r.FormValue("action") == "unblock" {
			action = events.BlocklistChangeActionUnblock
		}
		list, err = b.cli.UpdateBlocklist(ctx, jid, action, "")
	} else {
		list, err = b.cli.GetBlocklist(ctx, "")
	}
	if err != nil {
		httpErr(w, err, 502)
		return
	}
	out := []contact{}
	for _, item := range list.Items {
		jid := item.PN
		if jid.IsEmpty() {
			jid = b.chatKey(ctx, item.LID)
		}
		out = append(out, contact{JID: jid.String(), Name: b.displayName(ctx, jid), Phone: phoneNumber(jid)})
	}
	writeJSON(w, map[string]any{"blocked": out})
}
