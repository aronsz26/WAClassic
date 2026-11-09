package main

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// error counts for the app's diagnostics. only codes, never numbers, names or addresses.
// the app picks them up via /api/diag (only if the user said yes there) and that resets them.
type diagCounts struct {
	mu sync.Mutex
	m  map[string]int
}

var errCounts = &diagCounts{m: map[string]int{}}

func (d *diagCounts) add(code string) {
	if len(code) > 60 {
		code = code[:60]
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if _, ok := d.m[code]; !ok && len(d.m) >= 50 {
		return
	}
	d.m[code]++
}

func (d *diagCounts) take() map[string]int {
	d.mu.Lock()
	defer d.mu.Unlock()
	out := d.m
	d.m = map[string]int{}
	return out
}

var addrish = regexp.MustCompile(`[0-9a-fA-F:.\[\]]*[0-9][0-9a-fA-F:.\[\]]*:[0-9]+`)

// "read tcp 1.2.3.4:25567->5.6.7.8:1234: read: connection reset by peer" -> "connection reset by peer"
func errCode(err error) string {
	if err == nil {
		return ""
	}
	s := err.Error()
	if i := strings.LastIndex(s, ": "); i >= 0 {
		s = s[i+2:]
	}
	s = addrish.ReplaceAllString(s, "")
	if len(s) > 40 {
		s = s[:40]
	}
	return strings.TrimSpace(s)
}

func (b *Bridge) apiDiag(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]any{"counts": errCounts.take()})
}

// stdlib server log: counts tls handshake errors, still prints everything
type countingLog struct{}

func (countingLog) Write(p []byte) (int, error) {
	if i := bytes.Index(p, []byte("TLS handshake error")); i >= 0 {
		// "TLS handshake error from 1.2.3.4:5: tls: bad record MAC", the address goes
		line := strings.TrimSpace(string(p[i:]))
		if j := strings.Index(line, ": "); j >= 0 {
			line = line[j+2:]
		}
		// "read tcp a->b: read: connection reset by peer": only the reason
		if strings.HasPrefix(line, "read ") || strings.HasPrefix(line, "write ") {
			if j := strings.LastIndex(line, ": "); j >= 0 {
				line = line[j+2:]
			}
		}
		line = strings.TrimPrefix(strings.TrimPrefix(line, "local error: "), "tls: ")
		if len(line) > 46 {
			line = line[:46]
		}
		errCounts.add("tls handshake " + addrish.ReplaceAllString(line, ""))
	}
	return os.Stderr.Write(p)
}

// reads an upload, counts broken ones (e.g. "upload image bad record MAC").
// ?chunk=id: the body came in pieces before (see apiChunk)
func readUpload(r *http.Request, limit int64, kind string) ([]byte, error) {
	if id := r.URL.Query().Get("chunk"); id != "" {
		data, ok := takeChunks(id)
		if !ok {
			errCounts.add("upload " + kind + " chunks missing")
			return nil, errors.New("chunks missing")
		}
		if int64(len(data)) > limit {
			return nil, errors.New("too big")
		}
		return data, nil
	}
	data, err := io.ReadAll(io.LimitReader(r.Body, limit))
	if err != nil {
		errCounts.add("upload " + kind + " " + errCode(err))
	}
	return data, err
}

// pieces of one upload for phones with TLSFix: its openssl breaks writes over ~250 KB, so the app sends
// /api/chunk?id=..&off=.. pieces and then the normal request with ?chunk=id and no body
type chunkUpload struct {
	data    []byte
	touched time.Time
}

var chunks = struct {
	sync.Mutex
	m map[string]*chunkUpload
}{m: map[string]*chunkUpload{}}

func (b *Bridge) apiChunk(w http.ResponseWriter, r *http.Request) {
	id, off := r.URL.Query().Get("id"), r.URL.Query().Get("off")
	if r.Method != http.MethodPost || id == "" || len(id) > 64 {
		http.Error(w, "POST with id", http.StatusBadRequest)
		return
	}
	piece, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		errCounts.add("upload chunk " + errCode(err))
		http.Error(w, "broken piece", http.StatusBadRequest)
		return
	}
	chunks.Lock()
	defer chunks.Unlock()
	for k, c := range chunks.m {
		if time.Since(c.touched) > 10*time.Minute {
			delete(chunks.m, k)
		}
	}
	c := chunks.m[id]
	if c == nil {
		c = &chunkUpload{}
		chunks.m[id] = c
	}
	// the app retries a piece after an error, so the offset says where it goes
	if strconv.Itoa(len(c.data)) != off {
		http.Error(w, "wrong offset, have "+strconv.Itoa(len(c.data)), http.StatusConflict)
		return
	}
	if len(c.data)+len(piece) > 100<<20 {
		delete(chunks.m, id)
		http.Error(w, "too big", http.StatusRequestEntityTooLarge)
		return
	}
	c.data = append(c.data, piece...)
	c.touched = time.Now()
	writeJSON(w, map[string]int{"have": len(c.data)})
}

func takeChunks(id string) ([]byte, bool) {
	chunks.Lock()
	defer chunks.Unlock()
	c, ok := chunks.m[id]
	delete(chunks.m, id)
	if !ok {
		return nil, false
	}
	return c.data, true
}
