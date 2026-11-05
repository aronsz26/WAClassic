package main

import (
	"context"
	"log"
	"net/http"
	"time"

	"github.com/polymorfa/hypermeow/appstate"
	"github.com/polymorfa/hypermeow/proto/waCommon"
	"github.com/polymorfa/hypermeow/types"
	"github.com/polymorfa/hypermeow/types/events"
	"google.golang.org/protobuf/proto"
)

// DeleteChat removes a chat + messages + reactions from our store.
func (s *Store) DeleteChat(chat string) error {
	if _, err := s.db.Exec(`DELETE FROM reactions WHERE chat = ?`, chat); err != nil {
		return err
	}
	if _, err := s.db.Exec(`DELETE FROM messages WHERE chat = ?`, chat); err != nil {
		return err
	}
	_, err := s.db.Exec(`DELETE FROM chats WHERE jid = ?`, chat)
	s.chatsGone.Store(s.next())
	return err
}

// newestKey is what app state needs to delete a chat.
func (b *Bridge) newestKey(chat types.JID) (time.Time, *waCommon.MessageKey) {
	msgs, err := b.store.Messages(chat.String(), 0, 1)
	if err != nil || len(msgs) == 0 {
		return time.Now(), nil
	}
	m := msgs[0]
	key := &waCommon.MessageKey{RemoteJID: proto.String(chat.String()), FromMe: proto.Bool(m.FromMe), ID: proto.String(m.ID)}
	if chat.Server == types.GroupServer && !m.FromMe {
		key.Participant = proto.String(m.Sender)
	}
	return time.Unix(m.TS, 0), key
}

// deleteChat deletes locally, with everywhere also on the phone (app state "Delete chat").
func (b *Bridge) deleteChat(ctx context.Context, chatStr string, everywhere bool) error {
	chat, err := parseChat(chatStr)
	if err != nil {
		return err
	}
	if everywhere {
		ts, key := b.newestKey(chat)
		if err := b.cli.SendAppState(ctx, appstate.BuildDeleteChat(chat, ts, key, true)); err != nil {
			return err
		}
	}
	return b.store.DeleteChat(chat.String())
}

// apiDeleteChat: POST chat=<jid> (or all=1) everywhere=0|1.
func (b *Bridge) apiDeleteChat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	everywhere := r.FormValue("everywhere") == "1"
	var chats []string
	if r.FormValue("all") == "1" {
		list, err := b.store.Chats()
		if err != nil {
			httpErr(w, err, 500)
			return
		}
		for _, c := range list {
			chats = append(chats, c.JID)
		}
	} else if c := r.FormValue("chat"); c != "" {
		chats = []string{c}
	} else {
		http.Error(w, "chat or all needed", http.StatusBadRequest)
		return
	}
	for _, c := range chats {
		if err := b.deleteChat(r.Context(), c, everywhere); err != nil {
			log.Printf("delete chat: %v", err)
			httpErr(w, err, 502)
			return
		}
	}
	log.Printf("deleted %d chat(s), everywhere %v", len(chats), everywhere)
	b.store.notify()
	writeJSON(w, map[string]any{"ok": true, "deleted": len(chats)})
}

// onDeleteChat handles chats deleted on the phone.
func (b *Bridge) onDeleteChat(e *events.DeleteChat) {
	if e.FromFullSync {
		return
	}
	chat := b.chatKey(context.Background(), e.JID)
	if err := b.store.DeleteChat(chat.String()); err == nil {
		b.store.notify()
	}
}
