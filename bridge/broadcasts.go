package main

import (
	"database/sql"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/polymorfa/hypermeow/proto/waE2E"
	"github.com/polymorfa/hypermeow/types"
	"google.golang.org/protobuf/proto"
)

// 2.10 broadcasts: one message to many, everyone gets a normal message.
// We remember who got which message so the page can show ticks.

const broadcastSchema = `
CREATE TABLE IF NOT EXISTS broadcasts (
	id         INTEGER PRIMARY KEY AUTOINCREMENT,
	ts         INTEGER NOT NULL,
	kind       TEXT NOT NULL,
	text       TEXT NOT NULL,
	recipients TEXT NOT NULL
);`

const maxBroadcastRecipients = 50

// BroadcastRecipient is one recipient + their message.
type BroadcastRecipient struct {
	JID    string `json:"jid"`
	MsgID  string `json:"msgId"`
	Name   string `json:"name,omitempty"`
	Status int    `json:"status"`
	Seq    int64  `json:"seq,omitempty"`
}

// Broadcast as the app shows it.
type Broadcast struct {
	ID         int64                `json:"id"`
	TS         int64                `json:"ts"`
	Kind       string               `json:"kind"`
	Text       string               `json:"text"`
	Recipients []BroadcastRecipient `json:"recipients"`
}

func (s *Store) AddBroadcast(b *Broadcast) error {
	rec, _ := json.Marshal(b.Recipients)
	res, err := s.db.Exec(`INSERT INTO broadcasts (ts, kind, text, recipients) VALUES (?, ?, ?, ?)`, b.TS, b.Kind, b.Text, string(rec))
	if err != nil {
		return err
	}
	b.ID, _ = res.LastInsertId()
	return nil
}

func scanBroadcast(row interface{ Scan(...any) error }) (*Broadcast, error) {
	var b Broadcast
	var rec string
	if err := row.Scan(&b.ID, &b.TS, &b.Kind, &b.Text, &rec); err != nil {
		return nil, err
	}
	json.Unmarshal([]byte(rec), &b.Recipients)
	return &b, nil
}

func (s *Store) Broadcasts() ([]*Broadcast, error) {
	rows, err := s.db.Query(`SELECT id, ts, kind, text, recipients FROM broadcasts ORDER BY ts DESC, id DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []*Broadcast{}
	for rows.Next() {
		b, err := scanBroadcast(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

func (s *Store) Broadcast(id int64) (*Broadcast, error) {
	return scanBroadcast(s.db.QueryRow(`SELECT id, ts, kind, text, recipients FROM broadcasts WHERE id = ?`, id))
}

func (s *Store) DeleteBroadcast(id int64) error {
	_, err := s.db.Exec(`DELETE FROM broadcasts WHERE id = ?`, id)
	return err
}

// withStatus fills in names and ticks.
func (b *Bridge) withStatus(r *http.Request, bc *Broadcast) {
	for i := range bc.Recipients {
		rc := &bc.Recipients[i]
		jid, _ := types.ParseJID(rc.JID)
		rc.Name = b.displayName(r.Context(), jid)
		if m, _, err := b.store.MessageByID(rc.JID, rc.MsgID); err == nil {
			rc.Status, rc.Seq = m.Status, m.Seq
		}
	}
}

// apiBroadcasts: GET list, GET id= one, POST delete=<id> (only here).
func (b *Bridge) apiBroadcasts(w http.ResponseWriter, r *http.Request) {
	if id, _ := strconv.ParseInt(r.FormValue("delete"), 10, 64); id > 0 && r.Method == http.MethodPost {
		if err := b.store.DeleteBroadcast(id); err != nil {
			httpErr(w, err, 500)
			return
		}
		writeJSON(w, map[string]bool{"ok": true})
		return
	}
	if id, _ := strconv.ParseInt(r.FormValue("id"), 10, 64); id > 0 {
		bc, err := b.store.Broadcast(id)
		if err == sql.ErrNoRows {
			http.NotFound(w, r)
			return
		} else if err != nil {
			httpErr(w, err, 500)
			return
		}
		b.withStatus(r, bc)
		writeJSON(w, bc)
		return
	}
	list, err := b.store.Broadcasts()
	if err != nil {
		httpErr(w, err, 500)
		return
	}
	for _, bc := range list {
		b.withStatus(r, bc)
	}
	writeJSON(w, map[string]any{"broadcasts": list})
}

// apiBroadcastSend: POST recipients=... text=..., or a jpeg body with recipients/caption in the query.
func (b *Bridge) apiBroadcastSend(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var photo []byte
	text := ""
	q := r.URL.Query()
	if strings.HasPrefix(r.Header.Get("Content-Type"), "image/") {
		data, err := io.ReadAll(io.LimitReader(r.Body, 16<<20))
		if err != nil || len(data) == 0 {
			http.Error(w, "picture needed", http.StatusBadRequest)
			return
		}
		photo, text = data, q.Get("caption")
	} else {
		text = strings.TrimSpace(r.FormValue("text"))
	}
	recipients := strings.Split(firstNonEmpty(q.Get("recipients"), r.FormValue("recipients")), ",")
	if recipients[0] == "" || (photo == nil && text == "") {
		http.Error(w, "recipients and text or picture needed", http.StatusBadRequest)
		return
	}
	if len(recipients) > maxBroadcastRecipients {
		http.Error(w, "too many recipients", http.StatusBadRequest)
		return
	}
	bc := &Broadcast{TS: time.Now().Unix(), Kind: "text", Text: text}
	if photo != nil {
		bc.Kind = "image"
	}
	var failed []string
	for _, jid := range recipients {
		var m *Message
		var err error
		if photo != nil {
			m, err = b.sendImage(r.Context(), jid, photo, text, "")
		} else {
			m, err = b.sendText(r.Context(), jid, text, "")
		}
		if err != nil {
			log.Printf("broadcast to %s: %v", jid, err)
			failed = append(failed, jid)
			continue
		}
		bc.Recipients = append(bc.Recipients, BroadcastRecipient{JID: m.Chat, MsgID: m.ID})
	}
	if len(bc.Recipients) == 0 {
		http.Error(w, "not sent", http.StatusBadGateway)
		return
	}
	if err := b.store.AddBroadcast(bc); err != nil {
		httpErr(w, err, 500)
		return
	}
	log.Printf("broadcast %d sent to %d (%d failed)", bc.ID, len(bc.Recipients), len(failed))
	b.withStatus(r, bc)
	writeJSON(w, map[string]any{"broadcast": bc, "failed": failed})
}

// apiBroadcastResend: POST id= (rebroadcast).
func (b *Bridge) apiBroadcastResend(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	id, _ := strconv.ParseInt(r.FormValue("id"), 10, 64)
	old, err := b.store.Broadcast(id)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	// reuse the uploaded media
	var content *waE2E.Message
	if old.Kind == "image" && len(old.Recipients) > 0 {
		if _, raw, err := b.store.MessageByID(old.Recipients[0].JID, old.Recipients[0].MsgID); err == nil && len(raw) > 0 {
			content = &waE2E.Message{}
			if proto.Unmarshal(raw, content) != nil {
				content = nil
			}
		}
	}
	bc := &Broadcast{TS: time.Now().Unix(), Kind: old.Kind, Text: old.Text}
	for _, rc := range old.Recipients {
		var m *Message
		if content != nil {
			m, err = b.sendRaw(r, rc.JID, content, "image", old.Text)
		} else {
			m, err = b.sendText(r.Context(), rc.JID, old.Text, "")
		}
		if err != nil {
			log.Printf("rebroadcast to %s: %v", rc.JID, err)
			continue
		}
		bc.Recipients = append(bc.Recipients, BroadcastRecipient{JID: m.Chat, MsgID: m.ID})
	}
	if len(bc.Recipients) == 0 {
		http.Error(w, "not sent", http.StatusBadGateway)
		return
	}
	if err := b.store.AddBroadcast(bc); err != nil {
		httpErr(w, err, 500)
		return
	}
	b.withStatus(r, bc)
	writeJSON(w, map[string]any{"broadcast": bc})
}

// sendRaw sends a prepared message and stores it.
func (b *Bridge) sendRaw(r *http.Request, chatStr string, msg *waE2E.Message, kind, text string) (*Message, error) {
	chat, err := parseChat(chatStr)
	if err != nil {
		return nil, err
	}
	resp, err := b.cli.SendMessage(r.Context(), chat, msg)
	if err != nil {
		return nil, err
	}
	raw, _ := proto.Marshal(msg)
	m := &Message{ID: resp.ID, Chat: chat.String(), Sender: b.ownJID().String(), FromMe: true, TS: unix(resp.Timestamp),
		Kind: kind, Text: text, Status: statusSent}
	if _, err := b.store.AddMessage(m, raw, false); err != nil {
		return nil, err
	}
	b.store.notify()
	return m, nil
}
