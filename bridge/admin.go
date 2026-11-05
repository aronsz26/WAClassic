package main

import (
	"crypto/rand"
	"crypto/subtle"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/scrypt"
)

// Setup page at / (home listener only): link whatsapp, phone address + code, away settings, unlink.
// Password is set on the first visit.

//go:embed admin.html
var adminHTML []byte

type Admin struct {
	b       *Bridge
	setup   *Setup
	dataDir string
	tlsPort string // "" without tls
	envHost string // from env/flag until the page saves one
	envPort string
	repo    *Repo // cydia source

	mu  sync.Mutex
	cfg adminConfig
}

type adminConfig struct {
	Salt       string `json:"salt,omitempty"`
	Hash       string `json:"hash,omitempty"`
	PublicHost string `json:"publicHost"`
	PublicPort string `json:"publicPort"`
	Saved      bool   `json:"saved"` // overrides env
	// sessions (id -> expiry), on disk so a restart keeps them
	Sessions map[string]int64 `json:"sessions,omitempty"`
}

func newAdmin(b *Bridge, dataDir, tlsListen, envHost, envPort, token string) *Admin {
	a := &Admin{b: b, dataDir: dataDir, envHost: envHost, envPort: envPort}
	if tlsListen != "" {
		a.tlsPort = tlsListen[strings.LastIndex(tlsListen, ":")+1:]
	}
	if data, err := os.ReadFile(a.cfgPath()); err == nil {
		json.Unmarshal(data, &a.cfg)
	}
	a.setup = newSetup(dataDir, token, a.awayURL)
	return a
}

func (a *Admin) cfgPath() string { return filepath.Join(a.dataDir, "admin.json") }

func (a *Admin) saveCfg() error {
	data, _ := json.MarshalIndent(a.cfg, "", "  ")
	return os.WriteFile(a.cfgPath(), data, 0o600)
}

// public returns host + outside port for away mode.
func (a *Admin) public() (host, port string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	host, port = a.envHost, a.envPort
	if a.cfg.Saved {
		host, port = a.cfg.PublicHost, a.cfg.PublicPort
	}
	if port == "" {
		port = a.tlsPort
	}
	return
}

func (a *Admin) awayURL() string {
	host, port := a.public()
	if host == "" || a.tlsPort == "" {
		return ""
	}
	return "https://" + net.JoinHostPort(host, port)
}

func hashPassword(pw, salt string) string {
	key, err := scrypt.Key([]byte(pw), []byte(salt), 1<<15, 8, 1, 32)
	if err != nil {
		log.Fatal(err)
	}
	return hex.EncodeToString(key)
}

func randomHex(n int) string {
	buf := make([]byte, n)
	rand.Read(buf)
	return hex.EncodeToString(buf)
}

func (a *Admin) passwordSet() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.cfg.Hash != ""
}

func (a *Admin) loggedIn(r *http.Request) bool {
	c, err := r.Cookie("wa4s_admin")
	if err != nil {
		return false
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	exp, ok := a.cfg.Sessions[c.Value]
	return ok && time.Now().Unix() < exp
}

func (a *Admin) startSession(w http.ResponseWriter) {
	id := randomHex(24)
	a.mu.Lock()
	if a.cfg.Sessions == nil {
		a.cfg.Sessions = map[string]int64{}
	}
	now := time.Now().Unix()
	for k, exp := range a.cfg.Sessions {
		if exp < now {
			delete(a.cfg.Sessions, k)
		}
	}
	a.cfg.Sessions[id] = time.Now().Add(7 * 24 * time.Hour).Unix()
	a.saveCfg()
	a.mu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: "wa4s_admin", Value: id, Path: "/", HttpOnly: true,
		SameSite: http.SameSiteStrictMode, MaxAge: 7 * 24 * 3600})
}

func (a *Admin) register(mux *http.ServeMux) {
	mux.HandleFunc("/", a.page)
	mux.HandleFunc("/pair", func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, "/", http.StatusFound) })
	mux.HandleFunc("/api/setup", a.setup.apiSetup)
	mux.HandleFunc("/admin/state", a.apiState)
	mux.HandleFunc("/admin/password", a.post(false, a.apiPassword))
	mux.HandleFunc("/admin/login", a.post(false, a.apiLogin))
	mux.HandleFunc("/admin/logout", a.post(true, a.apiLogout))
	mux.HandleFunc("/admin/newcode", a.post(true, func(w http.ResponseWriter, r *http.Request) {
		a.setup.newCode()
		writeJSON(w, map[string]bool{"ok": true})
	}))
	mux.HandleFunc("/admin/public", a.post(true, a.apiPublic))
	mux.HandleFunc("/admin/assets", a.post(true, func(w http.ResponseWriter, r *http.Request) {
		a.b.assets.fetch()
		writeJSON(w, map[string]bool{"ok": true})
	}))
	mux.HandleFunc("/admin/unlink", a.post(true, func(w http.ResponseWriter, r *http.Request) {
		if err := a.b.unlink(r.Context()); err != nil {
			httpErr(w, err, 500)
			return
		}
		writeJSON(w, map[string]bool{"ok": true})
	}))
}

// post only accepts POSTs from the page (custom header = no cross site), checks login if needed.
func (a *Admin) post(auth bool, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.Header.Get("X-WA4S-Page") != "1" {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		if auth && !a.loggedIn(r) {
			http.Error(w, "log in first", http.StatusUnauthorized)
			return
		}
		h(w, r)
	}
}

func (a *Admin) page(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Write(adminHTML)
}

func (a *Admin) apiPassword(w http.ResponseWriter, r *http.Request) {
	pw := r.FormValue("password")
	if len(pw) < 6 {
		httpErr(w, errors.New("Please use at least 6 characters."), 400)
		return
	}
	a.mu.Lock()
	if a.cfg.Hash != "" {
		a.mu.Unlock()
		httpErr(w, errors.New("A password is already set."), 409)
		return
	}
	a.cfg.Salt = randomHex(16)
	a.cfg.Hash = hashPassword(pw, a.cfg.Salt)
	err := a.saveCfg()
	a.mu.Unlock()
	if err != nil {
		httpErr(w, err, 500)
		return
	}
	log.Printf("setup page: password set")
	a.startSession(w)
	writeJSON(w, map[string]bool{"ok": true})
}

func (a *Admin) apiLogin(w http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	salt, want := a.cfg.Salt, a.cfg.Hash
	a.mu.Unlock()
	if want == "" || subtle.ConstantTimeCompare([]byte(hashPassword(r.FormValue("password"), salt)), []byte(want)) != 1 {
		time.Sleep(2 * time.Second)
		httpErr(w, errors.New("Wrong password."), 401)
		return
	}
	a.startSession(w)
	writeJSON(w, map[string]bool{"ok": true})
}

func (a *Admin) apiLogout(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie("wa4s_admin"); err == nil {
		a.mu.Lock()
		delete(a.cfg.Sessions, c.Value)
		a.saveCfg()
		a.mu.Unlock()
	}
	http.SetCookie(w, &http.Cookie{Name: "wa4s_admin", Value: "", Path: "/", MaxAge: -1})
	writeJSON(w, map[string]bool{"ok": true})
}

func (a *Admin) apiPublic(w http.ResponseWriter, r *http.Request) {
	host := strings.TrimSpace(r.FormValue("host"))
	host = strings.TrimSuffix(strings.TrimPrefix(strings.TrimPrefix(host, "https://"), "http://"), "/")
	port := strings.TrimSpace(r.FormValue("port"))
	if strings.ContainsAny(host, " /:") {
		httpErr(w, errors.New("Enter only the name or IP address, without http:// or a port."), 400)
		return
	}
	if p, err := strconv.Atoi(port); port != "" && (err != nil || p < 1 || p > 65535) {
		httpErr(w, errors.New("The port must be a number from 1 to 65535."), 400)
		return
	}
	a.mu.Lock()
	a.cfg.PublicHost, a.cfg.PublicPort, a.cfg.Saved = host, port, true
	err := a.saveCfg()
	a.mu.Unlock()
	if err != nil {
		httpErr(w, err, 500)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

// inDocker: container IPs are useless to the phone.
func inDocker() bool {
	_, err := os.Stat("/.dockerenv")
	return err == nil
}

// lanAddresses returns private IPv4s (native bridge).
func lanAddresses() []string {
	var out []string
	addrs, _ := net.InterfaceAddrs()
	for _, ad := range addrs {
		ipn, ok := ad.(*net.IPNet)
		if !ok || ipn.IP.To4() == nil || !ipn.IP.IsPrivate() {
			continue
		}
		out = append(out, ipn.IP.String())
	}
	return out
}

func (a *Admin) apiState(w http.ResponseWriter, r *http.Request) {
	out := map[string]any{"passwordSet": a.passwordSet(), "loggedIn": a.loggedIn(r)}
	if !a.loggedIn(r) {
		writeJSON(w, out)
		return
	}
	cli := a.b.cli
	out["paired"] = cli.Store.ID != nil
	out["connected"] = cli.IsConnected() && cli.IsLoggedIn()
	if id := cli.Store.ID; id != nil {
		out["number"] = "+" + id.User
		out["pushName"] = cli.Store.PushName
	}
	code, left := a.setup.current()
	out["setupCode"], out["codeMinutes"] = code, left

	// use the address the browser used, unless it's localhost
	host, port, err := net.SplitHostPort(r.Host)
	if err != nil {
		host, port = r.Host, "80"
	}
	var phone []string
	if ip := net.ParseIP(host); host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		phone = append(phone, net.JoinHostPort(host, port))
	} else if !inDocker() {
		for _, ip := range lanAddresses() {
			phone = append(phone, net.JoinHostPort(ip, port))
		}
	}
	out["phoneAddresses"] = phone
	out["repoPackages"] = len(a.repo.debs())
	out["assets"] = a.b.assets.status()
	out["homePort"] = port
	pubHost, pubPort := a.public()
	out["tls"] = a.tlsPort != ""
	out["tlsPort"] = a.tlsPort
	out["publicHost"], out["publicPort"] = pubHost, pubPort
	out["awayURL"] = a.awayURL()
	out["fingerprint"] = a.setup.pin()
	writeJSON(w, out)
}
