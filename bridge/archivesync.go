package main

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"sync/atomic"
	"time"

	"github.com/polymorfa/hypermeow/appstate"
)

// Bridges from before 1.0.4 never stored the archive state, new archive actions only come in as they happen.
// Once per data dir: full resync of regular_low, its archive events fill the archived column.
var archiveSyncing atomic.Bool

func (b *Bridge) syncArchiveOnce() {
	mark := filepath.Join(b.dataDir, ".archive-synced")
	if _, err := os.Stat(mark); err == nil || !archiveSyncing.CompareAndSwap(false, true) {
		return
	}
	go func() {
		defer archiveSyncing.Store(false)
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		if err := b.cli.FetchAppState(ctx, appstate.WAPatchRegularLow, true, false); err != nil {
			// A stale local LTHash makes every delta fail. FetchAppState cannot repair
			// that version; request the authoritative snapshot from the primary phone.
			log.Printf("archive sync: %v, requesting fresh state from phone", err)
			if err = b.recoverAppState(ctx, appstate.WAPatchRegularLow); err != nil {
				log.Printf("archive sync recovery: %v, retrying in 5 minutes or on reconnect", err)
				time.AfterFunc(5*time.Minute, b.syncArchiveOnce)
				return
			}
		}
		os.WriteFile(mark, nil, 0600)
		log.Printf("archive sync done")
		b.store.notify()
	}()
}
