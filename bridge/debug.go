package main

import (
	"fmt"
	"net/http"
	"time"
)

// Test helpers: fake incoming message in "WA4S Test" (0@s.whatsapp.net) for testing notifications.
// /api/debug/clear removes it.
const testChat = "0@s.whatsapp.net"

func (b *Bridge) apiDebugIncoming(w http.ResponseWriter, r *http.Request) {
	text := r.FormValue("text")
	if text == "" {
		text = "Testnachricht"
	}
	m := &Message{
		ID:     fmt.Sprintf("TEST%d", time.Now().UnixNano()),
		Chat:   testChat,
		Sender: testChat,
		TS:     time.Now().Unix(),
		Kind:   "text",
		Text:   text,
		Status: statusDelivered,
	}
	if _, err := b.store.AddMessage(m, nil, true); err != nil {
		httpErr(w, err, 500)
		return
	}
	b.store.SetChatName(testChat, "WA4S Test")
	b.store.notify()
	writeJSON(w, m)
}

// messages to "WA4S Test" never reach whatsapp, they just fake the ticks (1.5s / 3s)
func (b *Bridge) sendTest(text string) (*Message, error) {
	m := &Message{
		ID:     fmt.Sprintf("TESTOUT%d", time.Now().UnixNano()),
		Chat:   testChat,
		Sender: testChat,
		FromMe: true,
		TS:     time.Now().Unix(),
		Kind:   "text",
		Text:   text,
		Status: statusSent,
	}
	if _, err := b.store.AddMessage(m, nil, true); err != nil {
		return nil, err
	}
	b.store.notify()
	go func() {
		for _, st := range []int{statusDelivered, statusRead} {
			time.Sleep(1500 * time.Millisecond)
			b.store.SetStatus(testChat, []string{m.ID}, st)
			b.store.notify()
		}
	}()
	return m, nil
}

func (b *Bridge) apiDebugClear(w http.ResponseWriter, r *http.Request) {
	b.store.db.Exec(`DELETE FROM messages WHERE chat = ?`, testChat)
	b.store.db.Exec(`DELETE FROM chats WHERE jid = ?`, testChat)
	b.store.notify()
	writeJSON(w, map[string]bool{"ok": true})
}
