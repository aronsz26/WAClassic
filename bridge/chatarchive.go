package main

import (
	"log"
	"net/http"

	"github.com/polymorfa/hypermeow/appstate"
)

// apiArchiveChat: POST chat=<jid>&archived=0|1.
func (b *Bridge) apiArchiveChat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	jid, err := parseChat(r.FormValue("chat"))
	if err != nil {
		httpErr(w, err, http.StatusBadRequest)
		return
	}
	archived := r.FormValue("archived") == "1"
	ts, key := b.newestKey(jid)
	if err := b.sendAppState(r.Context(), appstate.BuildArchive(jid, archived, ts, key)); err != nil {
		log.Printf("archive chat: %v", err)
		httpErr(w, err, http.StatusBadGateway)
		return
	}
	if err := b.store.SetArchived(jid.String(), archived); err != nil {
		httpErr(w, err, http.StatusInternalServerError)
		return
	}
	b.store.notify()
	writeJSON(w, map[string]any{"ok": true, "archived": archived})
}
