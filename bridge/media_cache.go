package main

import (
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

const bridgeMediaCacheLimit int64 = 1 << 30 // 1 GiB, media only; DB/session are outside mediaDir.

var mediaCacheMu sync.Mutex

func touchMediaCache(path string) {
	_ = os.Chtimes(path, time.Now(), time.Now())
}

func writeMediaCache(path string, data []byte) {
	if len(data) == 0 || int64(len(data)) > bridgeMediaCacheLimit {
		return
	}
	mediaCacheMu.Lock()
	defer mediaCacheMu.Unlock()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return
	}
	pruneMediaCacheLocked(filepath.Dir(path))
}

func pruneMediaCache(dir string) {
	mediaCacheMu.Lock()
	defer mediaCacheMu.Unlock()
	pruneMediaCacheLocked(dir)
}

func pruneMediaCacheLocked(dir string) {
	pruneMediaCacheToLocked(dir, bridgeMediaCacheLimit)
}

func pruneMediaCacheToLocked(dir string, limit int64) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	type cachedFile struct {
		path string
		mod  time.Time
		size int64
	}
	var files []cachedFile
	var total int64
	for _, entry := range entries {
		if !entry.Type().IsRegular() {
			continue
		}
		path := filepath.Join(dir, entry.Name())
		if filepath.Ext(entry.Name()) == ".tmp" {
			_ = os.Remove(path)
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		files = append(files, cachedFile{path, info.ModTime(), info.Size()})
		total += info.Size()
	}
	if total <= limit {
		return
	}
	sort.Slice(files, func(i, j int) bool { return files[i].mod.Before(files[j].mod) })
	for _, file := range files {
		if total <= limit {
			break
		}
		if os.Remove(file.path) == nil {
			total -= file.size
		}
	}
}
