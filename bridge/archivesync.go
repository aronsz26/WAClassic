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
			log.Printf("archive sync: %v, next connect tries again", err) // keys may not be there yet right after pairing
			return
		}
		os.WriteFile(mark, nil, 0600)
		log.Printf("archive sync done")
		b.store.notify()
	}()
}
