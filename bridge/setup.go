package main

import (
	"crypto/rand"
	"crypto/subtle"
	"fmt"
	"log"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Setup code: the bridge shows a 6 digit code, the app trades it once for the key + cert pin
// (nobody wants to type 32 hex chars on an iphone). Valid for setupValid, max setupMaxTries.
const (
	setupValid    = 30 * time.Minute
	setupMaxTries = 10
)

type Setup struct {
	token, dataDir string
	awayURL        func() string // away url, empty if not set

	mu      sync.Mutex
	code    string
	expires time.Time
	wrong   int
}

func newSetup(dataDir, token string, awayURL func() string) *Setup {
	s := &Setup{token: token, dataDir: dataDir, awayURL: awayURL}
	s.newCode()
	return s
}

// newCode makes a new code.
func (s *Setup) newCode() {
	n, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		log.Fatal(err)
	}
	s.mu.Lock()
	s.code = fmt.Sprintf("%06d", n.Int64())
	s.expires = time.Now().Add(setupValid)
	s.wrong = 0
	code := s.code
	s.mu.Unlock()
	os.WriteFile(filepath.Join(s.dataDir, "setup-code"), []byte(code+"\n"), 0o600)
	log.Printf("setup code for the app: %s (valid %d minutes; a new one on the setup page or after a restart)",
		code, int(setupValid.Minutes()))
}

// current returns the code + minutes left, "" if expired/locked.
func (s *Setup) current() (string, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	left := time.Until(s.expires)
	if left <= 0 || s.wrong >= setupMaxTries {
		return "", 0
	}
	return s.code, int(left.Minutes()) + 1
}

// read the pin each time, tls.sha256 is written later
func (s *Setup) pin() string {
	b, _ := os.ReadFile(filepath.Join(s.dataDir, "tls.sha256"))
	return strings.TrimSpace(string(b))
}

func (s *Setup) apiSetup(w http.ResponseWriter, r *http.Request) {
	got := strings.TrimSpace(r.FormValue("code"))
	s.mu.Lock()
	ok := s.code != "" && time.Now().Before(s.expires) && s.wrong < setupMaxTries &&
		subtle.ConstantTimeCompare([]byte(got), []byte(s.code)) == 1
	if !ok {
		s.wrong++
		if s.wrong == setupMaxTries {
			log.Printf("setup: too many wrong codes, make a new one on the setup page")
		}
	}
	s.mu.Unlock()
	if !ok {
		time.Sleep(2 * time.Second)
		http.Error(w, "wrong or expired setup code", http.StatusForbidden)
		return
	}
	log.Printf("setup: an app got the key")
	out := map[string]string{"token": s.token}
	if away := s.awayURL(); away != "" {
		out["awayURL"] = away
		out["pin"] = s.pin()
	}
	writeJSON(w, out)
}
