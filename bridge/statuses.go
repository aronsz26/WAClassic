package main

import (
	"context"
	"log"
	"net/http"
	"sort"
	"strconv"
	"time"

	"github.com/polymorfa/hypermeow/proto/waE2E"
	"github.com/polymorfa/hypermeow/types"
	"github.com/polymorfa/hypermeow/types/events"
	"google.golang.org/protobuf/proto"
)

// status updates of others (status@broadcast), own table so old apps never see them as a chat.
// opening one sends the view receipt like whatsapp does (poster sees it under views)
const statusSchema = `
CREATE TABLE IF NOT EXISTS statuses (
	seq     INTEGER PRIMARY KEY AUTOINCREMENT,
	id      TEXT NOT NULL UNIQUE,
	sender  TEXT NOT NULL,
	name    TEXT NOT NULL DEFAULT '',
	ts      INTEGER NOT NULL,
	kind    TEXT NOT NULL,
	text    TEXT NOT NULL DEFAULT '',
	bg      INTEGER NOT NULL DEFAULT 0,
	raw     BLOB,
	viewed  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS statuses_ts ON statuses(ts);
`

// sender as whatsapp sent it (maybe a lid), the receipt has to go there. fails if it exists, fine
const statusMigrate = `ALTER TABLE statuses ADD COLUMN sender_raw TEXT NOT NULL DEFAULT ''`

const statusLife = 24 * 60 * 60

type StatusItem struct {
	Seq    int64  `json:"seq"`
	ID     string `json:"id"`
	TS     int64  `json:"ts"`
	Kind   string `json:"kind"` // text, image, video
	Text   string `json:"text"` // the text or the caption
	BG     uint32 `json:"bg,omitempty"`
	Viewed bool   `json:"viewed"`
}

type StatusPerson struct {
	JID   string       `json:"jid"`
	Name  string       `json:"name"`
	Items []StatusItem `json:"items"` // oldest first, like they play
}

func (b *Bridge) onStatus(ctx context.Context, e *events.Message) {
	if e.Info.IsFromMe {
		return // own status comes later
	}
	msg := e.Message
	if p := msg.GetProtocolMessage(); p != nil {
		if p.GetType() == waE2E.ProtocolMessage_REVOKE {
			b.store.db.Exec(`DELETE FROM statuses WHERE id = ?`, p.GetKey().GetID())
		}
		return
	}
	kind, text := describe(msg)
	var bg uint32
	switch kind {
	case "text":
		bg = msg.GetExtendedTextMessage().GetBackgroundArgb()
	case "image", "video":
	default:
		return // voice statuses etc. later
	}
	ts := unix(e.Info.Timestamp)
	if ts < time.Now().Unix()-statusLife {
		return
	}
	sender := b.chatKey(ctx, e.Info.Sender)
	name := firstNonEmpty(b.store.ChatName(sender.String()), b.contactName(ctx, sender), e.Info.PushName)
	var raw []byte
	if kind != "text" {
		raw, _ = proto.Marshal(msg)
	}
	if _, err := b.store.db.Exec(`INSERT OR IGNORE INTO statuses (id, sender, sender_raw, name, ts, kind, text, bg, raw) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		e.Info.ID, sender.String(), e.Info.Sender.ToNonAD().String(), name, ts, kind, text, bg, raw); err != nil {
		log.Printf("store status: %v", err)
	}
	b.store.db.Exec(`DELETE FROM statuses WHERE ts < ?`, time.Now().Unix()-2*statusLife)
}

func isStatusChat(jid types.JID) bool {
	return jid == types.StatusBroadcastJID
}

// GET /api/statuses: people with updates from the last 24 h, newest person first
func (b *Bridge) apiStatuses(w http.ResponseWriter, r *http.Request) {
	rows, err := b.store.db.Query(`SELECT seq, id, sender, name, ts, kind, text, bg, viewed FROM statuses
		WHERE ts > ? ORDER BY ts`, time.Now().Unix()-statusLife)
	if err != nil {
		httpErr(w, err, 500)
		return
	}
	defer rows.Close()
	people := map[string]*StatusPerson{}
	newest := map[string]int64{}
	for rows.Next() {
		var it StatusItem
		var sender, name string
		if err := rows.Scan(&it.Seq, &it.ID, &sender, &name, &it.TS, &it.Kind, &it.Text, &it.BG, &it.Viewed); err != nil {
			continue
		}
		p := people[sender]
		if p == nil {
			p = &StatusPerson{JID: sender}
			people[sender] = p
		}
		// chat name wins, it's what the app shows elsewhere
		p.Name = firstNonEmpty(b.store.ChatName(sender), name, p.Name)
		p.Items = append(p.Items, it)
		newest[sender] = it.TS
	}
	out := make([]*StatusPerson, 0, len(people))
	for _, p := range people {
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return newest[out[i].JID] > newest[out[j].JID] })
	writeJSON(w, map[string]any{"people": out})
}

// GET /api/statuses/media?seq= (format= like /api/media), negative keys so video files don't clash with messages
func (b *Bridge) apiStatusMedia(w http.ResponseWriter, r *http.Request) {
	seq, _ := strconv.ParseInt(r.URL.Query().Get("seq"), 10, 64)
	var raw []byte
	if err := b.store.db.QueryRow(`SELECT raw FROM statuses WHERE seq = ?`, seq).Scan(&raw); err != nil || len(raw) == 0 {
		http.NotFound(w, r)
		return
	}
	b.serveRaw(w, r, -seq, raw)
}

// POST /api/statuses/seen seq=: viewed here and the read receipt to the poster
func (b *Bridge) apiStatusSeen(w http.ResponseWriter, r *http.Request) {
	seq, _ := strconv.ParseInt(r.FormValue("seq"), 10, 64)
	var id, sender, senderRaw string
	var ts int64
	var viewed bool
	err := b.store.db.QueryRow(`SELECT id, sender, sender_raw, ts, viewed FROM statuses WHERE seq = ?`, seq).Scan(&id, &sender, &senderRaw, &ts, &viewed)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	if _, err := b.store.db.Exec(`UPDATE statuses SET viewed = 1 WHERE seq = ?`, seq); err != nil {
		httpErr(w, err, 500)
		return
	}
	if !viewed {
		jid, err := types.ParseJID(firstNonEmpty(senderRaw, sender))
		if err == nil {
			// whatsmeow sends read-self if read receipts are off in privacy, same as the phone
			if err := b.cli.MarkRead(r.Context(), []types.MessageID{id}, time.Now(), types.StatusBroadcastJID, jid); err != nil {
				errCounts.add("status receipt")
				log.Printf("status receipt: %v", err)
			}
		}
	}
	writeJSON(w, map[string]any{"ok": true})
}
