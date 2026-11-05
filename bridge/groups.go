package main

import (
	"bytes"
	"fmt"
	"image"
	"io"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/polymorfa/hypermeow"
	"github.com/polymorfa/hypermeow/types"
)

// Groups: create, set picture.

// apiCreateGroup: subject (max 25) + participants. Returns the jid and who couldn't be added
// (privacy settings, invite only).
func (b *Bridge) apiCreateGroup(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	subject := strings.TrimSpace(r.FormValue("subject"))
	if subject == "" || utf8.RuneCountInString(subject) > 25 {
		http.Error(w, "the subject needs 1 to 25 characters", http.StatusBadRequest)
		return
	}
	var parts []types.JID
	for _, s := range strings.Split(r.FormValue("participants"), ",") {
		if s = strings.TrimSpace(s); s == "" {
			continue
		}
		jid, err := parseChat(s)
		if err != nil || jid.Server != types.DefaultUserServer {
			http.Error(w, "bad participant "+s, http.StatusBadRequest)
			return
		}
		parts = append(parts, jid)
	}
	if len(parts) == 0 {
		http.Error(w, "add at least one participant", http.StatusBadRequest)
		return
	}
	info, err := b.cli.CreateGroup(ctx, whatsmeow.ReqCreateGroup{Name: subject, Participants: parts})
	if err != nil {
		httpErr(w, err, 502)
		return
	}
	var failed []string
	for _, p := range info.Participants {
		if p.Error != 0 {
			failed = append(failed, b.displayName(ctx, b.chatKey(ctx, p.JID)))
		}
	}
	// show the chat right away with "You created group ..."
	jid := info.JID.String()
	b.store.SetChatName(jid, subject)
	own := b.ownJID().String()
	b.store.AddMessage(&Message{ID: fmt.Sprintf("CREATED%d", time.Now().UnixNano()), Chat: jid, Sender: own, FromMe: true,
		TS: time.Now().Unix(), Kind: "system", Text: fmt.Sprintf("You created group “%s”", subject), Status: statusRead}, nil, false)
	b.store.notify()
	writeJSON(w, map[string]any{"jid": jid, "name": subject, "failed": failed})
}

// apiGroupPhoto sets the group picture (empty body removes it).
func (b *Bridge) apiGroupPhoto(w http.ResponseWriter, r *http.Request) {
	jid, err := parseChat(r.URL.Query().Get("jid"))
	if err != nil || jid.Server != types.GroupServer {
		http.Error(w, "a group is needed", http.StatusBadRequest)
		return
	}
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
		if avatar, err = squareJPEG(img, 640); err != nil {
			httpErr(w, err, 500)
			return
		}
	}
	if _, err := b.cli.SetGroupPhoto(r.Context(), jid, avatar); err != nil {
		httpErr(w, err, 502)
		return
	}
	b.forgetAvatar(jid)
	writeJSON(w, map[string]any{"ok": true})
}

// systemLine adds a grey system line to a group chat.
func (b *Bridge) systemLine(chat, text string) {
	b.store.AddMessage(&Message{ID: fmt.Sprintf("SYS%d", time.Now().UnixNano()), Chat: chat, Sender: b.ownJID().String(),
		FromMe: true, TS: time.Now().Unix(), Kind: "system", Text: text, Status: statusRead}, nil, false)
	b.store.notify()
}

func groupFromForm(w http.ResponseWriter, r *http.Request) (types.JID, bool) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return types.EmptyJID, false
	}
	jid, err := parseChat(r.FormValue("jid"))
	if err != nil || jid.Server != types.GroupServer {
		http.Error(w, "a group is needed", http.StatusBadRequest)
		return types.EmptyJID, false
	}
	return jid, true
}

// apiGroupSubject: POST jid= subject= (1-25 chars).
func (b *Bridge) apiGroupSubject(w http.ResponseWriter, r *http.Request) {
	jid, ok := groupFromForm(w, r)
	if !ok {
		return
	}
	subject := strings.TrimSpace(r.FormValue("subject"))
	if subject == "" || utf8.RuneCountInString(subject) > 25 {
		http.Error(w, "the subject needs 1 to 25 characters", http.StatusBadRequest)
		return
	}
	if err := b.cli.SetGroupName(r.Context(), jid, subject); err != nil {
		httpErr(w, err, 502)
		return
	}
	b.store.SetChatName(jid.String(), subject)
	b.systemLine(jid.String(), fmt.Sprintf("You changed the subject to “%s”", subject))
	writeJSON(w, map[string]any{"ok": true, "name": subject})
}

// apiGroupParticipants: POST jid= add= / remove= (admins only), "failed" = couldn't add.
func (b *Bridge) apiGroupParticipants(w http.ResponseWriter, r *http.Request) {
	jid, ok := groupFromForm(w, r)
	if !ok {
		return
	}
	action, who := whatsmeow.ParticipantChangeAdd, r.FormValue("add")
	if who == "" {
		action, who = whatsmeow.ParticipantChangeRemove, r.FormValue("remove")
	}
	person, err := parseChat(who)
	if err != nil || who == "" {
		http.Error(w, "add or remove needed", http.StatusBadRequest)
		return
	}
	res, err := b.cli.UpdateGroupParticipants(r.Context(), jid, []types.JID{person}, action)
	if err != nil {
		httpErr(w, err, 502)
		return
	}
	var failed []string
	for _, p := range res {
		if p.Error != 0 {
			failed = append(failed, b.displayName(r.Context(), b.chatKey(r.Context(), p.JID)))
		}
	}
	name := b.displayName(r.Context(), person)
	if len(failed) == 0 {
		if action == whatsmeow.ParticipantChangeAdd {
			b.systemLine(jid.String(), fmt.Sprintf("You added %s", name))
		} else {
			b.systemLine(jid.String(), fmt.Sprintf("%s was removed", name))
		}
	}
	writeJSON(w, map[string]any{"ok": len(failed) == 0, "failed": failed})
}

// apiGroupLeave: POST jid= (exit group + delete chat).
func (b *Bridge) apiGroupLeave(w http.ResponseWriter, r *http.Request) {
	jid, ok := groupFromForm(w, r)
	if !ok {
		return
	}
	if err := b.cli.LeaveGroup(r.Context(), jid); err != nil {
		httpErr(w, err, 502)
		return
	}
	b.store.DeleteChat(jid.String())
	b.store.notify()
	writeJSON(w, map[string]any{"ok": true})
}
