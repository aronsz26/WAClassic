package main

import (
	"context"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/polymorfa/hypermeow/appstate"
	"github.com/polymorfa/hypermeow/store"
	"github.com/polymorfa/hypermeow/types"
)

// Info pages: contact/group info, mute, all media.

// mutedUntil: 0 = not muted, -1 = forever, else unix time.
func (b *Bridge) mutedUntil(ctx context.Context, chat types.JID) int64 {
	s, err := b.cli.Store.ChatSettings.GetChatSettings(ctx, chat)
	if err != nil || !s.Found || s.MutedUntil.IsZero() {
		return 0
	}
	if s.MutedUntil.Equal(store.MutedForever) {
		return -1
	}
	if s.MutedUntil.Before(time.Now()) {
		return 0
	}
	return s.MutedUntil.Unix()
}

func (b *Bridge) isMuted(ctx context.Context, chat string) bool {
	jid, err := types.ParseJID(chat)
	return err == nil && b.mutedUntil(ctx, jid) != 0
}

// country code length: 1 and 7 are one digit, the rest 2 or 3
var cc2 = map[string]bool{"20": true, "27": true, "30": true, "31": true, "32": true, "33": true, "34": true, "36": true,
	"39": true, "40": true, "41": true, "43": true, "44": true, "45": true, "46": true, "47": true, "48": true, "49": true,
	"51": true, "52": true, "53": true, "54": true, "55": true, "56": true, "57": true, "58": true, "60": true, "61": true,
	"62": true, "63": true, "64": true, "65": true, "66": true, "81": true, "82": true, "84": true, "86": true, "90": true,
	"91": true, "92": true, "93": true, "94": true, "95": true, "98": true}

// "+43 677 ..." from the jid
func phoneNumber(jid types.JID) string {
	n := jid.User
	if jid.Server != types.DefaultUserServer || len(n) < 7 {
		return ""
	}
	cc := 3
	if n[0] == '1' || n[0] == '7' {
		cc = 1
	} else if cc2[n[:2]] {
		cc = 2
	}
	rest := n[cc:]
	return "+" + n[:cc] + " " + rest[:3] + " " + rest[3:]
}

// apiContactInfo: name, number, about, presence, mute, media count.
func (b *Bridge) apiContactInfo(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	jid, err := parseChat(r.URL.Query().Get("jid"))
	if err != nil || jid.Server == types.GroupServer {
		http.Error(w, "a person is needed", http.StatusBadRequest)
		return
	}
	jid = b.chatKey(ctx, jid)
	out := map[string]any{"jid": jid.String(), "name": b.displayName(ctx, jid), "phone": phoneNumber(jid),
		"mutedUntil": b.mutedUntil(ctx, jid), "media": b.store.MediaCount(jid.String())}
	if infos, err := b.cli.GetUserInfo(ctx, []types.JID{jid}); err == nil {
		for _, info := range infos {
			out["about"] = info.Status
			if info.VerifiedName != nil && info.VerifiedName.Details != nil {
				out["business"] = info.VerifiedName.Details.GetVerifiedName()
			}
		}
	}
	b.cli.SubscribePresence(ctx, jid)
	b.presMu.Lock()
	out["presence"] = *b.presenceFor(jid.String())
	b.presMu.Unlock()
	writeJSON(w, out)
}

type participant struct {
	JID        string `json:"jid"`
	Name       string `json:"name"`
	Phone      string `json:"phone,omitempty"`
	Admin      bool   `json:"admin,omitempty"`
	SuperAdmin bool   `json:"superAdmin,omitempty"`
	Me         bool   `json:"me,omitempty"`
	About      string `json:"about,omitempty"`
}

// groupDetails adds group info stuff to /api/chatinfo.
func (b *Bridge) groupDetails(ctx context.Context, chat types.JID, info *types.GroupInfo, out map[string]any) {
	own := b.cli.Store.GetJID().ToNonAD()
	var parts []participant
	for _, p := range info.Participants {
		jid := b.chatKey(ctx, p.JID)
		me := jid == own || (!p.PhoneNumber.IsEmpty() && p.PhoneNumber.ToNonAD() == own)
		name := b.displayName(ctx, jid)
		if me {
			name = "You"
		}
		parts = append(parts, participant{JID: jid.String(), Name: name, Phone: phoneNumber(jid), Admin: p.IsAdmin,
			SuperAdmin: p.IsSuperAdmin, Me: me})
	}
	// all abouts in one request
	var ask []types.JID
	for _, p := range parts {
		if jid, err := types.ParseJID(p.JID); err == nil && !p.Me && len(ask) < 256 {
			ask = append(ask, jid)
		}
	}
	if infos, err := b.cli.GetUserInfo(ctx, ask); err == nil {
		about := map[string]string{}
		for jid, info := range infos {
			about[b.chatKey(ctx, jid).String()] = info.Status
		}
		for i := range parts {
			parts[i].About = about[parts[i].JID]
		}
	}
	// admins first, then by name, me last
	sort.SliceStable(parts, func(i, j int) bool {
		a, c := parts[i], parts[j]
		if a.Me != c.Me {
			return c.Me
		}
		if a.Admin != c.Admin {
			return a.Admin
		}
		return strings.ToLower(a.Name) < strings.ToLower(c.Name)
	})
	out["participants"] = parts
	out["topic"] = info.Topic
	if !info.GroupCreated.IsZero() {
		out["created"] = info.GroupCreated.Unix()
	}
	if !info.OwnerJID.IsEmpty() {
		owner := b.chatKey(ctx, info.OwnerJID)
		if owner == own {
			out["creator"] = "You"
		} else {
			out["creator"] = b.displayName(ctx, owner)
		}
	}
	out["mutedUntil"] = b.mutedUntil(ctx, chat)
	out["media"] = b.store.MediaCount(chat.String())
}

// apiMute: hours 8/168/8760, -1 forever, 0 unmute. synced with whatsapp.
func (b *Bridge) apiMute(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	chat, err := parseChat(r.FormValue("chat"))
	if err != nil {
		httpErr(w, err, 400)
		return
	}
	hours, _ := strconv.Atoi(r.FormValue("hours"))
	var until time.Time
	var patch appstate.PatchInfo
	switch {
	case hours == 0:
		patch = appstate.BuildMute(chat, false, 0)
	case hours < 0:
		patch, until = appstate.BuildMute(chat, true, 0), store.MutedForever
	default:
		d := time.Duration(hours) * time.Hour
		patch, until = appstate.BuildMute(chat, true, d), time.Now().Add(d)
	}
	if err := b.sendAppState(ctx, patch); err != nil {
		httpErr(w, err, 502)
		return
	}
	b.cli.Store.ChatSettings.PutMutedUntil(ctx, chat, until)
	b.store.TouchChat(chat.String())
	b.store.notify()
	writeJSON(w, map[string]any{"mutedUntil": b.mutedUntil(ctx, chat)})
}

// apiChatMedia lists photos/videos, newest first.
func (b *Bridge) apiChatMedia(w http.ResponseWriter, r *http.Request) {
	chat := r.URL.Query().Get("chat")
	if _, err := parseChat(chat); err != nil {
		httpErr(w, err, 400)
		return
	}
	items, err := b.store.Media(chat, 500)
	if err != nil {
		httpErr(w, err, 500)
		return
	}
	writeJSON(w, map[string]any{"media": items})
}
