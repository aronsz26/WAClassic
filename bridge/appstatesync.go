package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"slices"
	"sync"
	"time"

	"github.com/polymorfa/hypermeow"
	"github.com/polymorfa/hypermeow/appstate"
	"github.com/polymorfa/hypermeow/types/events"
)

// Mute, delete chat and name are app state patches. A bad LTHash means our copy of that state is off.
// First a full resync from the server. If the server's patches don't add up for us either, ask the
// phone for a fresh copy (like WhatsApp Web does) and try once more.

var recoverWait = struct {
	sync.Mutex
	m map[appstate.WAPatchName][]chan struct{}
}{m: map[appstate.WAPatchName][]chan struct{}{}}

func (b *Bridge) sendAppState(ctx context.Context, patch appstate.PatchInfo) error {
	err := b.cli.SendAppState(ctx, patch)
	if err == nil {
		return nil
	}
	errCounts.add("appstate send failed " + string(patch.Type))
	log.Printf("app state %s: %v, resyncing", patch.Type, err)
	if syncErr := b.cli.FetchAppState(ctx, patch.Type, true, false); syncErr != nil {
		log.Printf("app state %s: resync: %v", patch.Type, syncErr)
	} else if err = b.cli.SendAppState(ctx, patch); err == nil {
		return nil
	} else {
		log.Printf("app state %s: still failing after resync: %v", patch.Type, err)
	}
	if recErr := b.recoverAppState(ctx, patch.Type); recErr != nil {
		errCounts.add("appstate recovery failed " + string(patch.Type))
		log.Printf("app state %s: recovery from the phone: %v", patch.Type, recErr)
		return fmt.Errorf("%w (resync and recovery from the phone failed too, is the phone online?)", err)
	}
	if err = b.cli.SendAppState(ctx, patch); err != nil {
		log.Printf("app state %s: still failing after recovery: %v", patch.Type, err)
		return err
	}
	errCounts.add("appstate recovered " + string(patch.Type))
	log.Printf("app state %s: works again after recovery from the phone", patch.Type)
	return nil
}

// recoverAppState asks the phone for the collection and waits for the library to store it.
// keeps going in the background if the iPhone gives up first, so the next try works.
func (b *Bridge) recoverAppState(ctx context.Context, name appstate.WAPatchName) error {
	// the library ignores a copy that isn't newer than ours, and ours is the broken one
	if err := b.cli.Store.AppState.DeleteAppStateVersion(ctx, string(name)); err != nil {
		return err
	}
	done := make(chan struct{}, 1)
	recoverWait.Lock()
	recoverWait.m[name] = append(recoverWait.m[name], done)
	recoverWait.Unlock()
	bg, cancel := context.WithTimeout(context.WithoutCancel(ctx), 45*time.Second)
	defer cancel()
	if _, err := b.cli.SendPeerMessage(bg, whatsmeow.BuildAppStateRecoveryRequest(name)); err != nil {
		return err
	}
	log.Printf("app state %s: asked the phone for a fresh copy", name)
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-bg.Done():
		return fmt.Errorf("no answer from the phone")
	}
}

func (b *Bridge) onAppStateSyncComplete(e *events.AppStateSyncComplete) {
	if !e.Recovery {
		return
	}
	log.Printf("app state %s: fresh copy from the phone, v%d", e.Name, e.Version)
	recoverWait.Lock()
	waiting := recoverWait.m[e.Name]
	delete(recoverWait.m, e.Name)
	recoverWait.Unlock()
	for _, c := range waiting {
		c <- struct{}{}
	}
}

// /api/debug/appstate?name=regular_high&do=recover|sync: test the recovery from the phone, or a full resync.
func (b *Bridge) apiDebugAppState(w http.ResponseWriter, r *http.Request) {
	name := appstate.WAPatchName(r.FormValue("name"))
	if !slices.Contains(appstate.AllPatchNames[:], name) {
		http.Error(w, "unknown name", http.StatusBadRequest)
		return
	}
	var err error
	if r.FormValue("do") == "recover" {
		err = b.recoverAppState(r.Context(), name)
	} else {
		err = b.cli.FetchAppState(r.Context(), name, true, false)
	}
	version, _, verErr := b.cli.Store.AppState.GetAppStateVersion(r.Context(), string(name))
	if err == nil {
		err = verErr
	}
	if err != nil {
		httpErr(w, err, 502)
		return
	}
	writeJSON(w, map[string]any{"name": name, "version": version})
}
