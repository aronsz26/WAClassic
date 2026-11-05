package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// Pairing from the app: GET /api/pair/qr (410 = linked, 503 = no code yet),
// POST /api/pair/unlink logs out and resets so it can be linked again.

const resetMarker = "reset" // marker file, wipe chats on next start

// resetData runs before opening the dbs so the old account's chats are gone.
func resetData(dataDir string) {
	marker := filepath.Join(dataDir, resetMarker)
	if _, err := os.Stat(marker); err != nil {
		return
	}
	for _, name := range []string{"wa4s.db", "wa4s.db-wal", "wa4s.db-shm", "media", "avatars"} {
		if err := os.RemoveAll(filepath.Join(dataDir, name)); err != nil {
			log.Fatalf("reset: %v", err)
		}
	}
	os.Remove(marker)
	log.Printf("reset: chats of the previous account deleted")
}

func (b *Bridge) apiUnlink(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	if err := b.unlink(r.Context()); err != nil {
		httpErr(w, err, 500)
		return
	}
	writeJSON(w, map[string]any{"ok": true})
}

// unlink logs out and restarts empty.
func (b *Bridge) unlink(ctx context.Context) error {
	if b.cli.Store.ID != nil {
		ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
		err := b.cli.Logout(ctx)
		cancel()
		if err != nil {
			// even if offline, forget the device here
			log.Printf("unlink: %v", err)
			b.cli.Disconnect()
			if b.cli.Store.ID != nil {
				if err := b.cli.Store.Delete(context.Background()); err != nil {
					return err
				}
			}
		}
	}
	if err := os.WriteFile(filepath.Join(b.dataDir, resetMarker), nil, 0o600); err != nil {
		return err
	}
	b.restartSoon("unlinked")
	return nil
}

// restartSoon exits, systemd/docker restarts us with a fresh device.
func (b *Bridge) restartSoon(why string) {
	go func() {
		time.Sleep(time.Second)
		log.Printf("%s: restarting", why)
		os.Exit(1)
	}()
}
