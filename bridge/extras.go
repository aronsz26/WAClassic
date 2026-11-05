package main

import (
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/polymorfa/hypermeow"
	"github.com/polymorfa/hypermeow/types"
	"github.com/polymorfa/hypermeow/types/events"
)

// Presence is shown under the chat title: online, last seen, typing.
type Presence struct {
	Chat       string `json:"chat"`
	Online     bool   `json:"online"`
	LastSeen   int64  `json:"lastSeen,omitempty"`
	Typing     bool   `json:"typing"`
	TypingName string `json:"typingName,omitempty"` // typing in groups
	Upd        int64  `json:"-"`
	typingAt   time.Time
}

func (b *Bridge) presenceFor(chat string) *Presence {
	p := b.presence[chat]
	if p == nil {
		p = &Presence{Chat: chat}
		b.presence[chat] = p
	}
	return p
}

func (b *Bridge) onPresence(e *events.Presence) {
	chat := b.chatKey(context.Background(), e.From).String()
	b.presMu.Lock()
	p := b.presenceFor(chat)
	p.Online = !e.Unavailable
	if !e.LastSeen.IsZero() {
		p.LastSeen = e.LastSeen.Unix()
	} else if e.Unavailable && p.LastSeen == 0 {
		p.LastSeen = 0
	}
	if e.Unavailable {
		p.Typing = false
	}
	p.Upd = b.store.next()
	b.presMu.Unlock()
	b.store.notify()
}

func (b *Bridge) onChatPresence(e *events.ChatPresence) {
	ctx := context.Background()
	chat := b.chatKey(ctx, e.Chat)
	b.presMu.Lock()
	p := b.presenceFor(chat.String())
	p.Typing = e.State == types.ChatPresenceComposing
	p.typingAt = time.Now()
	p.TypingName = ""
	if p.Typing && chat.Server == types.GroupServer {
		p.TypingName = firstName(b.displayName(ctx, b.chatKey(ctx, e.Sender)))
	}
	if p.Typing && chat.Server != types.GroupServer {
		p.Online = true
	}
	p.Upd = b.store.next()
	b.presMu.Unlock()
	b.store.notify()
	if p.Typing {
		// "paused" doesn't always come, time out typing
		time.AfterFunc(20*time.Second, func() {
			b.presMu.Lock()
			if p.Typing && time.Since(p.typingAt) >= 20*time.Second {
				p.Typing = false
				p.Upd = b.store.next()
				b.presMu.Unlock()
				b.store.notify()
				return
			}
			b.presMu.Unlock()
		})
	}
}

func (b *Bridge) presenceSince(since int64) []Presence {
	b.presMu.Lock()
	defer b.presMu.Unlock()
	var out []Presence
	for _, p := range b.presence {
		if p.Upd > since {
			out = append(out, *p)
		}
	}
	return out
}

func firstName(name string) string {
	if i := strings.IndexByte(name, ' '); i > 0 && !strings.HasPrefix(name, "+") {
		return name[:i]
	}
	return name
}

// apiPresence sets us online while the app is open.
// whatsapp only sends others' presence while we're available.
func (b *Bridge) apiPresence(w http.ResponseWriter, r *http.Request) {
	state := types.PresenceUnavailable
	if r.FormValue("state") == "available" {
		state = types.PresenceAvailable
	}
	if err := b.cli.SendPresence(r.Context(), state); err != nil {
		httpErr(w, err, 502)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

// apiChatInfo: group members or a person's presence (and subscribes to it).
func (b *Bridge) apiChatInfo(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	chat, err := parseChat(r.URL.Query().Get("chat"))
	if err != nil {
		httpErr(w, err, 400)
		return
	}
	out := map[string]any{"chat": chat.String()}
	if chat.Server == types.GroupServer {
		info, err := b.cli.GetGroupInfo(ctx, chat)
		if err != nil {
			httpErr(w, err, 502)
			return
		}
		own := b.cli.Store.GetJID().ToNonAD()
		var names []string
		for _, part := range info.Participants {
			jid := b.chatKey(ctx, part.JID)
			if jid == own || (!part.PhoneNumber.IsEmpty() && part.PhoneNumber.ToNonAD() == own) {
				continue
			}
			names = append(names, firstName(b.displayName(ctx, jid)))
		}
		sort.Strings(names)
		out["members"] = append(names, "You")
		out["name"] = info.Name
		b.groupDetails(ctx, chat, info, out)
	} else {
		out["mutedUntil"] = b.mutedUntil(ctx, chat)
		b.cli.SubscribePresence(ctx, chat)
		b.presMu.Lock()
		p := *b.presenceFor(chat.String())
		b.presMu.Unlock()
		out["presence"] = p
	}
	writeJSON(w, out)
}

// apiAvatar returns the avatar jpeg, 404 if none.
func (b *Bridge) apiAvatar(w http.ResponseWriter, r *http.Request) {
	jid, err := parseChat(r.URL.Query().Get("jid"))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	name := strings.NewReplacer("@", "_", ":", "_", "/", "_").Replace(jid.String())
	full := r.URL.Query().Get("full") == "1" // full size for info pages
	if full {
		name += "_full"
	}
	file := filepath.Join(b.avatarDir, name+".jpg")
	none := filepath.Join(b.avatarDir, name+".none")
	fresh := func(path string) bool {
		st, err := os.Stat(path)
		return err == nil && time.Since(st.ModTime()) < 24*time.Hour
	}
	if fresh(none) {
		http.NotFound(w, r)
		return
	}
	if !fresh(file) {
		data, err := b.fetchAvatar(r.Context(), jid, !full)
		switch {
		case err == nil:
			os.WriteFile(file, data, 0o600)
			os.Remove(none)
		case errors.Is(err, whatsmeow.ErrProfilePictureNotSet), errors.Is(err, whatsmeow.ErrProfilePictureUnauthorized), errors.Is(err, errNoPicture):
			os.WriteFile(none, nil, 0o600)
			os.Remove(file)
			http.NotFound(w, r)
			return
		default:
			if _, statErr := os.Stat(file); statErr != nil {
				httpErr(w, err, 502)
				return
			}
			// keep the old one
		}
	}
	w.Header().Set("Content-Type", "image/jpeg")
	http.ServeFile(w, r, file)
}

var errNoPicture = errors.New("no picture")

func (b *Bridge) fetchAvatar(ctx context.Context, jid types.JID, preview bool) ([]byte, error) {
	info, err := b.cli.GetProfilePictureInfo(ctx, jid, &whatsmeow.GetProfilePictureParams{Preview: preview})
	if err != nil {
		return nil, err
	}
	if info == nil || info.URL == "" {
		return nil, errNoPicture
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, info.URL, nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, errors.New(resp.Status)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 2<<20))
}
