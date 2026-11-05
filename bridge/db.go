package main

import (
	"database/sql"
	"sync"
	"sync/atomic"
	"time"
)

// Message is a row as the app sees it.
type Message struct {
	Seq    int64  `json:"seq"`
	ID     string `json:"id"`
	Chat   string `json:"chat"`
	Sender string `json:"sender"`
	Name   string `json:"name,omitempty"`
	// for notifications
	ChatName string `json:"chatName,omitempty"`
	FromMe   bool   `json:"fromMe"`
	TS       int64  `json:"ts"`
	Kind     string `json:"kind"`
	Text     string `json:"text"`
	Status   int    `json:"status"`
	Secs     int    `json:"secs,omitempty"`
	Upd      int64  `json:"upd"`
	// upd when stored; later changes only bump Upd
	Created   int64      `json:"-"`
	Reactions []Reaction `json:"reactions,omitempty"`
	Quote     *Quote     `json:"quote,omitempty"`
}

// quoted message of a reply
type Quote struct {
	ID     string `json:"id"`
	Sender string `json:"sender"`
	Name   string `json:"name,omitempty"`
	FromMe bool   `json:"fromMe"`
	Kind   string `json:"kind"`
	Text   string `json:"text"`
}

// Reaction: one emoji per person.
type Reaction struct {
	Sender string `json:"sender"`
	Name   string `json:"name,omitempty"`
	FromMe bool   `json:"fromMe"`
	Emoji  string `json:"emoji"`
	TS     int64  `json:"ts"`
}

// Chat is a chat list entry.
type Chat struct {
	JID      string `json:"jid"`
	Name     string `json:"name"`
	LastTS   int64  `json:"lastTS"`
	LastText string `json:"lastText"`
	Unread   int    `json:"unread"`
	Group    bool   `json:"group"`
	// last message
	LastKind       string `json:"lastKind"`
	LastFromMe     bool   `json:"lastFromMe"`
	LastStatus     int    `json:"lastStatus"`
	LastSecs       int    `json:"lastSecs,omitempty"`
	LastSender     string `json:"-"`
	LastSenderName string `json:"lastSenderName,omitempty"`
	Muted          bool   `json:"muted,omitempty"`
}

const (
	statusPending   = 0
	statusSent      = 1
	statusDelivered = 2
	statusRead      = 3
)

const schema = `
CREATE TABLE IF NOT EXISTS messages (
	seq     INTEGER PRIMARY KEY AUTOINCREMENT,
	id      TEXT NOT NULL,
	chat    TEXT NOT NULL,
	sender  TEXT NOT NULL,
	from_me INTEGER NOT NULL,
	ts      INTEGER NOT NULL,
	kind    TEXT NOT NULL,
	text    TEXT NOT NULL,
	status  INTEGER NOT NULL,
	raw     BLOB,
	upd     INTEGER NOT NULL,
	UNIQUE(chat, id)
);
CREATE INDEX IF NOT EXISTS messages_chat ON messages(chat, ts);
CREATE INDEX IF NOT EXISTS messages_upd ON messages(upd);
CREATE TABLE IF NOT EXISTS reactions (
	chat    TEXT NOT NULL,
	msg_id  TEXT NOT NULL,
	sender  TEXT NOT NULL,
	from_me INTEGER NOT NULL,
	emoji   TEXT NOT NULL,
	ts      INTEGER NOT NULL,
	PRIMARY KEY (chat, msg_id, sender)
);
CREATE TABLE IF NOT EXISTS chats (
	jid     TEXT PRIMARY KEY,
	name    TEXT NOT NULL DEFAULT '',
	last_ts INTEGER NOT NULL DEFAULT 0,
	unread  INTEGER NOT NULL DEFAULT 0,
	upd     INTEGER NOT NULL DEFAULT 0
);
`

// Store keeps our messages/chats, separate from whatsmeow's db.
type Store struct {
	db  *sql.DB
	upd atomic.Int64
	// upd of the last deleted chat
	chatsGone atomic.Int64
	mu        sync.Mutex
	wake      chan struct{}
}

func openStore(db *sql.DB) (*Store, error) {
	if _, err := db.Exec(schema); err != nil {
		return nil, err
	}
	if _, err := db.Exec(broadcastSchema); err != nil {
		return nil, err
	}
	// voice message length (fails if the column exists, fine)
	db.Exec(`ALTER TABLE messages ADD COLUMN secs INTEGER NOT NULL DEFAULT 0`)
	// stored time, so bg poll can tell new from changed
	db.Exec(`ALTER TABLE messages ADD COLUMN created INTEGER NOT NULL DEFAULT 0`)
	// replies
	for _, col := range []string{"quote_id", "quote_sender", "quote_kind", "quote_text"} {
		db.Exec(`ALTER TABLE messages ADD COLUMN ` + col + ` TEXT NOT NULL DEFAULT ''`)
	}
	s := &Store{db: db, wake: make(chan struct{})}
	var maxUpd sql.NullInt64
	db.QueryRow(`SELECT MAX(m) FROM (SELECT MAX(upd) m FROM messages UNION SELECT MAX(upd) FROM chats)`).Scan(&maxUpd)
	// calls/presence use numbers too but aren't stored, so the max can be lower than what the phone
	// already saw. never start below the clock (ms)
	s.upd.Store(max(maxUpd.Int64, time.Now().UnixMilli()))
	return s, nil
}

func (s *Store) next() int64 { return s.upd.Add(1) }

// notify wakes all long polls.
func (s *Store) notify() {
	s.mu.Lock()
	close(s.wake)
	s.wake = make(chan struct{})
	s.mu.Unlock()
}

func (s *Store) waitChan() <-chan struct{} {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.wake
}

// AddMessage stores a message once, false if it existed.
func (s *Store) AddMessage(m *Message, raw []byte, countUnread bool) (bool, error) {
	m.Upd = s.next()
	m.Created = m.Upd
	var q Quote
	if m.Quote != nil {
		q = *m.Quote
	}
	res, err := s.db.Exec(`INSERT OR IGNORE INTO messages (id, chat, sender, from_me, ts, kind, text, status, raw, upd, secs, created,
		quote_id, quote_sender, quote_kind, quote_text) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		m.ID, m.Chat, m.Sender, m.FromMe, m.TS, m.Kind, m.Text, m.Status, raw, m.Upd, m.Secs, m.Created,
		q.ID, q.Sender, q.Kind, q.Text)
	if err != nil {
		return false, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return false, nil
	}
	m.Seq, _ = res.LastInsertId()
	unread := 0
	if countUnread && !m.FromMe {
		unread = 1
	}
	_, err = s.db.Exec(`INSERT INTO chats (jid, last_ts, unread, upd) VALUES (?, ?, ?, ?)
		ON CONFLICT(jid) DO UPDATE SET last_ts = MAX(last_ts, excluded.last_ts), unread = unread + excluded.unread, upd = excluded.upd`,
		m.Chat, m.TS, unread, m.Upd)
	return true, err
}

// SetStatus only raises the status.
func (s *Store) SetStatus(chat string, ids []string, status int) error {
	for _, id := range ids {
		if _, err := s.db.Exec(`UPDATE messages SET status = ?, upd = ? WHERE chat = ? AND id = ? AND status < ?`,
			status, s.next(), chat, id, status); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) SetChatName(jid, name string) error {
	_, err := s.db.Exec(`INSERT INTO chats (jid, name, upd) VALUES (?, ?, ?)
		ON CONFLICT(jid) DO UPDATE SET name = excluded.name, upd = excluded.upd`, jid, name, s.next())
	return err
}

func (s *Store) SetUnread(jid string, unread int) error {
	_, err := s.db.Exec(`UPDATE chats SET unread = ?, upd = ? WHERE jid = ?`, unread, s.next(), jid)
	return err
}

func (s *Store) Chats() ([]Chat, error) {
	rows, err := s.db.Query(`SELECT c.jid, c.name, c.last_ts, c.unread, COALESCE(m.kind, ''), COALESCE(m.text, ''),
		COALESCE(m.from_me, 0), COALESCE(m.sender, ''), COALESCE(m.status, 0), COALESCE(m.secs, 0)
		FROM chats c LEFT JOIN messages m ON m.seq = (SELECT seq FROM messages WHERE chat = c.jid ORDER BY ts DESC, seq DESC LIMIT 1)
		WHERE c.last_ts > 0 ORDER BY c.last_ts DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Chat
	for rows.Next() {
		var c Chat
		if err := rows.Scan(&c.JID, &c.Name, &c.LastTS, &c.Unread, &c.LastKind, &c.LastText,
			&c.LastFromMe, &c.LastSender, &c.LastStatus, &c.LastSecs); err != nil {
			return nil, err
		}
		if c.LastText == "" && c.LastKind != "" && c.LastKind != "audio" {
			c.LastText = kindLabel(c.LastKind)
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (s *Store) UnreadTotal() int {
	var n int
	s.db.QueryRow(`SELECT COALESCE(SUM(unread), 0) FROM chats`).Scan(&n)
	return n
}

func (s *Store) ChatName(jid string) string {
	var name string
	s.db.QueryRow(`SELECT name FROM chats WHERE jid = ?`, jid).Scan(&name)
	return name
}

const msgCols = `seq, id, chat, sender, from_me, ts, kind, text, status, upd, secs, created,
	quote_id, quote_sender, quote_kind, quote_text`

func scanMessages(rows *sql.Rows) ([]Message, error) {
	defer rows.Close()
	var out []Message
	for rows.Next() {
		var m Message
		var q Quote
		if err := rows.Scan(&m.Seq, &m.ID, &m.Chat, &m.Sender, &m.FromMe, &m.TS, &m.Kind, &m.Text, &m.Status, &m.Upd, &m.Secs,
			&m.Created, &q.ID, &q.Sender, &q.Kind, &q.Text); err != nil {
			return nil, err
		}
		if q.ID != "" {
			m.Quote = &q
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// Messages returns the newest messages, oldest first. before > 0 pages back.
func (s *Store) Messages(chat string, before int64, limit int) ([]Message, error) {
	if before <= 0 {
		before = 1 << 62
	}
	rows, err := s.db.Query(`SELECT * FROM (SELECT `+msgCols+` FROM messages WHERE chat = ? AND seq < ?
		ORDER BY ts DESC, seq DESC LIMIT ?) ORDER BY ts, seq`, chat, before, limit)
	if err != nil {
		return nil, err
	}
	return scanMessages(rows)
}

// Updates returns new or changed messages since upd.
func (s *Store) Updates(since int64, limit int) ([]Message, error) {
	rows, err := s.db.Query(`SELECT `+msgCols+` FROM messages WHERE upd > ? ORDER BY upd LIMIT ?`, since, limit)
	if err != nil {
		return nil, err
	}
	return scanMessages(rows)
}

func (s *Store) ChatsChangedSince(since int64) bool {
	if s.chatsGone.Load() > since {
		return true
	}
	var n int
	s.db.QueryRow(`SELECT COUNT(*) FROM chats WHERE upd > ?`, since).Scan(&n)
	return n > 0
}

func (s *Store) Raw(seq int64) (chat string, kind string, raw []byte, err error) {
	err = s.db.QueryRow(`SELECT chat, kind, raw FROM messages WHERE seq = ?`, seq).Scan(&chat, &kind, &raw)
	return
}

// UnreadIncoming lists messages that still need a read receipt.
func (s *Store) UnreadIncoming(chat string, limit int) ([]Message, error) {
	rows, err := s.db.Query(`SELECT `+msgCols+` FROM messages WHERE chat = ? AND from_me = 0 AND status < ?
		ORDER BY ts DESC LIMIT ?`, chat, statusRead, limit)
	if err != nil {
		return nil, err
	}
	return scanMessages(rows)
}

func (s *Store) MarkIncomingRead(chat string) error {
	_, err := s.db.Exec(`UPDATE messages SET status = ? WHERE chat = ? AND from_me = 0 AND status < ?`,
		statusRead, chat, statusRead)
	return err
}

func previewText(last string) string {
	for i := 0; i < len(last); i++ {
		if last[i] == 31 {
			kind, text := last[:i], last[i+1:]
			if text != "" {
				return text
			}
			return kindLabel(kind)
		}
	}
	return last
}

func kindLabel(kind string) string {
	switch kind {
	case "image":
		return "Photo"
	case "video":
		return "Video"
	case "audio":
		return "Audio"
	case "sticker":
		return "Sticker"
	case "document":
		return "Document"
	case "location":
		return "Location"
	case "contact":
		return "Contact"
	}
	return "Message"
}

func unix(t time.Time) int64 {
	if t.IsZero() {
		return time.Now().Unix()
	}
	return t.Unix()
}

// AudioWithoutLength: old voice msgs/videos without a stored length.
func (s *Store) AudioWithoutLength() (map[int64][]byte, error) {
	rows, err := s.db.Query(`SELECT seq, raw FROM messages WHERE kind IN ('audio', 'video') AND secs = 0 AND raw IS NOT NULL`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int64][]byte{}
	for rows.Next() {
		var seq int64
		var raw []byte
		if err := rows.Scan(&seq, &raw); err != nil {
			return nil, err
		}
		out[seq] = raw
	}
	return out, rows.Err()
}

func (s *Store) SetSecs(seq int64, secs int) error {
	_, err := s.db.Exec(`UPDATE messages SET secs = ? WHERE seq = ?`, secs, seq)
	return err
}

// MediaItem is a photo/video for All Media.
type MediaItem struct {
	Seq    int64  `json:"seq"`
	Kind   string `json:"kind"`
	TS     int64  `json:"ts"`
	FromMe bool   `json:"fromMe"`
	Secs   int    `json:"secs,omitempty"`
}

func (s *Store) MediaCount(chat string) int {
	var n int
	s.db.QueryRow(`SELECT COUNT(*) FROM messages WHERE chat = ? AND kind IN ('image', 'video')`, chat).Scan(&n)
	return n
}

func (s *Store) Media(chat string, limit int) ([]MediaItem, error) {
	rows, err := s.db.Query(`SELECT seq, kind, ts, from_me, secs FROM messages WHERE chat = ? AND kind IN ('image', 'video')
		ORDER BY ts DESC, seq DESC LIMIT ?`, chat, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []MediaItem{}
	for rows.Next() {
		var m MediaItem
		if err := rows.Scan(&m.Seq, &m.Kind, &m.TS, &m.FromMe, &m.Secs); err != nil {
			return nil, err
		}
		items = append(items, m)
	}
	return items, rows.Err()
}

// TouchChat marks a chat changed so the app reloads the list.
func (s *Store) TouchChat(chat string) {
	s.db.Exec(`UPDATE chats SET upd = ? WHERE jid = ?`, s.next(), chat)
}

// SetReaction sets or removes (empty) a reaction, false if the message is unknown.
func (s *Store) SetReaction(chat, msgID, sender string, fromMe bool, emoji string, ts int64) bool {
	if emoji == "" {
		s.db.Exec(`DELETE FROM reactions WHERE chat = ? AND msg_id = ? AND sender = ?`, chat, msgID, sender)
	} else {
		s.db.Exec(`INSERT INTO reactions (chat, msg_id, sender, from_me, emoji, ts) VALUES (?, ?, ?, ?, ?, ?)
			ON CONFLICT(chat, msg_id, sender) DO UPDATE SET emoji = excluded.emoji, ts = excluded.ts
			WHERE excluded.ts >= reactions.ts`, chat, msgID, sender, fromMe, emoji, ts)
	}
	res, err := s.db.Exec(`UPDATE messages SET upd = ? WHERE chat = ? AND id = ?`, s.next(), chat, msgID)
	if err != nil {
		return false
	}
	n, _ := res.RowsAffected()
	return n > 0
}

// addReactions fills in reactions, oldest first.
func (s *Store) addReactions(msgs []Message) {
	for i := range msgs {
		rows, err := s.db.Query(`SELECT sender, from_me, emoji, ts FROM reactions WHERE chat = ? AND msg_id = ? ORDER BY ts`,
			msgs[i].Chat, msgs[i].ID)
		if err != nil {
			continue
		}
		for rows.Next() {
			var r Reaction
			if rows.Scan(&r.Sender, &r.FromMe, &r.Emoji, &r.TS) == nil {
				msgs[i].Reactions = append(msgs[i].Reactions, r)
			}
		}
		rows.Close()
	}
}

// MessageByID finds a message by whatsapp id.
func (s *Store) MessageByID(chat, id string) (*Message, []byte, error) {
	var m Message
	var raw []byte
	var q Quote
	err := s.db.QueryRow(`SELECT `+msgCols+`, raw FROM messages WHERE chat = ? AND id = ?`, chat, id).Scan(
		&m.Seq, &m.ID, &m.Chat, &m.Sender, &m.FromMe, &m.TS, &m.Kind, &m.Text, &m.Status, &m.Upd, &m.Secs, &m.Created,
		&q.ID, &q.Sender, &q.Kind, &q.Text, &raw)
	if err != nil {
		return nil, nil, err
	}
	if q.ID != "" {
		m.Quote = &q
	}
	return &m, raw, nil
}
