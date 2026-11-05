package main

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"crypto/md5"
	"crypto/sha1"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// Small cydia repo at /repo/ (lan only) with the app debs that ship with the bridge.
// Plain http because cydia on iOS 4-6 can't do modern TLS. Updating the bridge updates the app.

//go:embed repo-icon.png
var repoIcon []byte

type Repo struct {
	dir string

	mu       sync.Mutex
	stamp    string // what the index was built from
	packages []byte
	gz       []byte
	release  []byte
}

func newRepo(dir string) *Repo {
	r := &Repo{dir: dir}
	if n := len(r.debs()); n > 0 {
		log.Printf("cydia source: %d package(s) from %s at /repo/", n, dir)
	}
	return r
}

func (r *Repo) debs() []os.DirEntry {
	entries, _ := os.ReadDir(r.dir)
	var out []os.DirEntry
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".deb") {
			out = append(out, e)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name() < out[j].Name() })
	return out
}

// index rebuilds Packages/Packages.gz/Release when the folder changed.
func (r *Repo) index() error {
	var stamp strings.Builder
	debs := r.debs()
	for _, e := range debs {
		info, err := e.Info()
		if err != nil {
			return err
		}
		fmt.Fprintf(&stamp, "%s %d %d\n", e.Name(), info.Size(), info.ModTime().UnixNano())
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.packages != nil && stamp.String() == r.stamp {
		return nil
	}
	var pk bytes.Buffer
	for _, e := range debs {
		data, err := os.ReadFile(filepath.Join(r.dir, e.Name()))
		if err != nil {
			return err
		}
		control, err := debControl(data)
		if err != nil {
			log.Printf("cydia source: %s: %v", e.Name(), err)
			continue
		}
		m, s1, s256 := md5.Sum(data), sha1.Sum(data), sha256.Sum256(data)
		pk.WriteString(strings.TrimRight(control, "\n"))
		fmt.Fprintf(&pk, "\nFilename: debs/%s\nSize: %d\nMD5sum: %s\nSHA1: %s\nSHA256: %s\n\n",
			e.Name(), len(data), hex.EncodeToString(m[:]), hex.EncodeToString(s1[:]), hex.EncodeToString(s256[:]))
	}
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	zw.Write(pk.Bytes())
	zw.Close()
	r.packages, r.gz, r.stamp = pk.Bytes(), gz.Bytes(), stamp.String()
	r.release = []byte(fmt.Sprintf("Origin: WA Classic\nLabel: WA Classic\nSuite: stable\nVersion: 1.0\nCodename: wa-classic\n"+
		"Architectures: iphoneos-arm\nComponents: main\nDescription: WA Classic from your own bridge (%s)\nDate: %s\n",
		time.Now().UTC().Format("2006-01-02"), time.Now().UTC().Format(time.RFC1123)))
	return nil
}

func (r *Repo) serve(w http.ResponseWriter, req *http.Request) {
	name := strings.TrimPrefix(req.URL.Path, "/repo/")
	for strings.HasPrefix(name, "./") {
		name = name[2:]
	}
	if strings.Contains(name, "..") {
		http.NotFound(w, req)
		return
	}
	if name == "" || name == "CydiaIcon.png" || strings.HasPrefix(name, "debs/") {
		// handled below
	} else if err := r.index(); err != nil {
		httpErr(w, err, 500)
		return
	}
	w.Header().Set("Cache-Control", "no-cache")
	switch {
	case name == "" || name == "index.html":
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, `<!doctype html><meta name="viewport" content="width=device-width"><title>WA Classic source</title>`+
			`<body style="font:17px Helvetica,sans-serif;margin:30px">This is a Cydia source. In Cydia tap `+
			`<b>Sources</b> &rsaquo; <b>Edit</b> &rsaquo; <b>Add</b> and enter this page's address.</body>`)
	case name == "CydiaIcon.png":
		w.Header().Set("Content-Type", "image/png")
		w.Write(repoIcon)
	case name == "Packages":
		r.mu.Lock()
		data := r.packages
		r.mu.Unlock()
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Write(data)
	case name == "Packages.gz":
		r.mu.Lock()
		data := r.gz
		r.mu.Unlock()
		w.Header().Set("Content-Type", "application/x-gzip")
		w.Write(data)
	case name == "Release":
		r.mu.Lock()
		data := r.release
		r.mu.Unlock()
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Write(data)
	case strings.HasPrefix(name, "debs/") && !strings.Contains(name[5:], "/") && strings.HasSuffix(name, ".deb"):
		w.Header().Set("Content-Type", "application/x-debian-package")
		http.ServeFile(w, req, filepath.Join(r.dir, filepath.Base(name)))
	default:
		http.NotFound(w, req) // cydia falls back to the next file
	}
}

// debControl reads the control file out of a .deb.
func debControl(deb []byte) (string, error) {
	if !bytes.HasPrefix(deb, []byte("!<arch>\n")) {
		return "", errors.New("not a .deb")
	}
	rd := bufio.NewReader(bytes.NewReader(deb[8:]))
	for {
		hdr := make([]byte, 60)
		if _, err := io.ReadFull(rd, hdr); err != nil {
			return "", errors.New("no control.tar.gz")
		}
		name := strings.TrimRight(strings.TrimSpace(string(hdr[:16])), "/")
		var size int64
		fmt.Sscanf(strings.TrimSpace(string(hdr[48:58])), "%d", &size)
		body := make([]byte, size)
		if _, err := io.ReadFull(rd, body); err != nil {
			return "", err
		}
		if size%2 == 1 {
			rd.ReadByte()
		}
		if name != "control.tar.gz" {
			continue
		}
		zr, err := gzip.NewReader(bytes.NewReader(body))
		if err != nil {
			return "", err
		}
		tr := tar.NewReader(zr)
		for {
			th, err := tr.Next()
			if err != nil {
				return "", errors.New("no control file")
			}
			if filepath.Base(th.Name) == "control" {
				c, err := io.ReadAll(tr)
				return string(c), err
			}
		}
	}
}
