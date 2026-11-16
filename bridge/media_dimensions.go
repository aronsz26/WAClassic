package main

import (
	"database/sql"

	"github.com/polymorfa/hypermeow/proto/waE2E"
	"google.golang.org/protobuf/proto"
)

func dimensionsFromMessage(msg *waE2E.Message) (int, int) {
	if msg == nil {
		return 0, 0
	}
	if image := msg.GetImageMessage(); image != nil {
		return int(image.GetWidth()), int(image.GetHeight())
	}
	if video := msg.GetVideoMessage(); video != nil {
		return int(video.GetWidth()), int(video.GetHeight())
	}
	if video := msg.GetPtvMessage(); video != nil {
		return int(video.GetWidth()), int(video.GetHeight())
	}
	return 0, 0
}

func dimensionsFromRaw(raw []byte) (int, int) {
	var msg waE2E.Message
	if len(raw) == 0 || proto.Unmarshal(raw, &msg) != nil {
		return 0, 0
	}
	return dimensionsFromMessage(&msg)
}

func migrateMediaDimensions(db *sql.DB) error {
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS wa_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)`); err != nil {
		return err
	}
	var migrated string
	err := db.QueryRow(`SELECT value FROM wa_meta WHERE key = 'media_dimensions_v1'`).Scan(&migrated)
	if err == nil && migrated == "done" {
		return nil
	}
	if err != nil && err != sql.ErrNoRows {
		return err
	}
	rows, err := db.Query(`SELECT seq, raw FROM messages
		WHERE media_width = 0 AND kind IN ('image', 'video') AND raw IS NOT NULL`)
	if err != nil {
		return err
	}
	type dimensions struct {
		seq, width, height int
	}
	var found []dimensions
	for rows.Next() {
		var seq int
		var raw []byte
		if err := rows.Scan(&seq, &raw); err != nil {
			rows.Close()
			return err
		}
		width, height := dimensionsFromRaw(raw)
		if width > 0 && height > 0 {
			found = append(found, dimensions{seq: seq, width: width, height: height})
		}
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	if err := rows.Close(); err != nil {
		return err
	}
	stmt, err := db.Prepare(`UPDATE messages SET media_width = ?, media_height = ? WHERE seq = ?`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, item := range found {
		if _, err := stmt.Exec(item.width, item.height, item.seq); err != nil {
			return err
		}
	}
	_, err = db.Exec(`INSERT OR REPLACE INTO wa_meta (key, value) VALUES ('media_dimensions_v1', 'done')`)
	return err
}
