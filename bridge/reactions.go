package main

import (
	"context"
	"net/http"
	"time"

	"github.com/polymorfa/hypermeow/proto/waE2E"
	"github.com/polymorfa/hypermeow/proto/waWeb"
	"github.com/polymorfa/hypermeow/types"
)

// onReaction stores live or history reactions.
func (b *Bridge) onReaction(ctx context.Context, chat, sender types.JID, fromMe bool, r *waE2E.ReactionMessage, live bool) {
	if fromMe {
		sender = b.ownJID()
	}
	ts := r.GetSenderTimestampMS() / 1000
	if ts == 0 {
		ts = time.Now().Unix()
	}
	if b.store.SetReaction(chat.String(), r.GetKey().GetID(), sender.String(), fromMe, r.GetText(), ts) && live {
		b.store.notify()
	}
}

// historyReactions stores reactions from history sync.
func (b *Bridge) historyReactions(ctx context.Context, chat types.JID, wm *waWeb.WebMessageInfo) {
	for _, r := range wm.GetReactions() {
		key := r.GetKey()
		fromMe := key.GetFromMe()
		var sender types.JID
		switch {
		case fromMe:
			sender = b.ownJID()
		case key.GetParticipant() != "":
			p, err := types.ParseJID(key.GetParticipant())
			if err != nil {
				continue
			}
			sender = b.chatKey(ctx, p)
		default:
			sender = chat
		}
		ts := r.GetSenderTimestampMS() / 1000
		b.store.SetReaction(chat.String(), wm.GetKey().GetID(), sender.String(), fromMe, r.GetText(), ts)
	}
}

// apiReact sends a reaction (empty = remove).
func (b *Bridge) apiReact(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	chatStr, id, emoji := r.FormValue("chat"), r.FormValue("id"), r.FormValue("emoji")
	chat, err := parseChat(chatStr)
	if err != nil || id == "" {
		http.Error(w, "chat and id needed", http.StatusBadRequest)
		return
	}
	target, _, err := b.store.MessageByID(chat.String(), id)
	if err != nil {
		http.Error(w, "message not found", http.StatusNotFound)
		return
	}
	sender, _ := types.ParseJID(target.Sender)
	if target.FromMe {
		sender = b.ownJID()
	}
	if _, err := b.cli.SendMessage(r.Context(), chat, b.cli.BuildReaction(chat, sender, id, emoji)); err != nil {
		httpErr(w, err, 502)
		return
	}
	b.store.SetReaction(chat.String(), id, b.ownJID().String(), true, emoji, time.Now().Unix())
	b.store.notify()
	writeJSON(w, map[string]bool{"ok": true})
}
