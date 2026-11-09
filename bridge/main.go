// wa4s-bridge links to whatsapp as a companion device and serves a small HTTP/JSON api
// for the old iphone. The phone stays the main device.
package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"flag"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/polymorfa/hypermeow"
	"github.com/polymorfa/hypermeow/proto/waE2E"
	"github.com/polymorfa/hypermeow/store"
	"github.com/polymorfa/hypermeow/store/sqlstore"
	"github.com/polymorfa/hypermeow/types"
	waLog "github.com/polymorfa/hypermeow/util/log"
	qrcode "github.com/skip2/go-qrcode"
	"google.golang.org/protobuf/proto"
	_ "modernc.org/sqlite"
)

// set from the release tag, the app warns when it is older than the app
var version = "dev"

func openSQLite(path string) (*sql.DB, error) {
	return sql.Open("sqlite", "file:"+path+"?_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_pragma=busy_timeout(10000)")
}

// loadToken reads or creates the api key.
func loadToken(dir string) (string, error) {
	path := filepath.Join(dir, "token")
	if b, err := os.ReadFile(path); err == nil {
		return strings.TrimSpace(string(b)), nil
	}
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	tok := hex.EncodeToString(buf)
	return tok, os.WriteFile(path, []byte(tok+"\n"), 0o600)
}

// env returns the env var or the default (for docker).
func env(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

func main() {
	listen := flag.String("listen", env("WA4S_LISTEN", "127.0.0.1:8097"), "address for the HTTP API")
	dataDir := flag.String("data", env("WA4S_DATA", "./data"), "folder for the session, messages and token")
	tlsListen := flag.String("tls-listen", env("WA4S_TLS_LISTEN", ""), "address for the API over TLS from outside, e.g. :25567 (empty: off)")
	publicHost := flag.String("public-host", env("WA4S_PUBLIC_HOST", ""), "name or IP the app uses away from home (router/DynDNS), handed out by the setup code")
	debsDir := flag.String("debs", env("WA4S_DEBS", "./debs"), "folder with the app's .deb packages, offered to Cydia at /repo/")
	publicPort := flag.String("public-port", env("WA4S_PUBLIC_PORT", ""), "port the router forwards to the TLS listener (default: the -tls-listen port)")
	assetsAuto := flag.Bool("assets-auto", env("WA4S_ASSETS", "") == "auto", "download the WhatsApp 2.10 look from archive.org at the start, without the bridge page")
	demo := flag.Bool("demo", false, "demo mode: made-up English chats for screenshots, no WhatsApp")
	flag.Parse()
	if *demo {
		runDemo(*listen)
		return
	}

	if err := os.MkdirAll(*dataDir, 0o700); err != nil {
		log.Fatal(err)
	}
	token, err := loadToken(*dataDir)
	if err != nil {
		log.Fatal(err)
	}

	store.SetOSInfo("WA Classic", [3]uint32{0, 1, 0}) // name in Linked Devices
	store.DeviceProps.RequireFullSync = proto.Bool(false)

	resetData(*dataDir)
	ctx := context.Background()
	sessDB, err := openSQLite(filepath.Join(*dataDir, "session.db"))
	if err != nil {
		log.Fatal(err)
	}
	container := sqlstore.NewWithDB(sessDB, "sqlite3", waLog.Stdout("Store", "WARN", false))
	if err := container.Upgrade(ctx); err != nil {
		log.Fatal(err)
	}
	device, err := container.GetFirstDevice(ctx)
	if err != nil {
		log.Fatal(err)
	}
	appDB, err := openSQLite(filepath.Join(*dataDir, "wa4s.db"))
	if err != nil {
		log.Fatal(err)
	}
	st, err := openStore(appDB)
	if err != nil {
		log.Fatal(err)
	}

	cli := whatsmeow.NewClient(device, waLog.Stdout("WA", "INFO", false))
	b := &Bridge{cli: cli, store: st, dataDir: *dataDir}
	cli.AddEventHandler(b.handle)
	b.calls = newCalls(b) // needs to exist before connecting
	b.mediaDir = filepath.Join(*dataDir, "media")
	os.MkdirAll(b.mediaDir, 0o700)
	b.avatarDir = filepath.Join(*dataDir, "avatars")
	os.MkdirAll(b.avatarDir, 0o700)
	b.presence = map[string]*Presence{}
	b.assets = newAssetLooks(*dataDir)
	if *assetsAuto {
		b.assets.fetch()
	}
	b.backfillSecs()

	if cli.Store.ID == nil {
		log.Printf("not linked yet: set up the iPhone from the bridge page (http://<this computer>:%s/), it shows the QR code", (*listen)[strings.LastIndex(*listen, ":")+1:])
		go b.pairLoop()
	} else if err := cli.Connect(); err != nil {
		log.Fatal(err)
	}

	// mux = everything (local), public = api only (tls)
	mux := http.NewServeMux()
	public := http.NewServeMux()
	// setup page + setup code only on the lan listener
	b.admin = newAdmin(b, *dataDir, *tlsListen, *publicHost, *publicPort, token)
	b.admin.register(mux)
	b.admin.repo = newRepo(*debsDir)

	api := func(path string, h http.HandlerFunc) {
		guarded := func(w http.ResponseWriter, r *http.Request) {
			got := r.Header.Get("X-WA4S-Token")
			if got == "" {
				got = r.URL.Query().Get("token")
			}
			if subtle.ConstantTimeCompare([]byte(got), []byte(token)) != 1 {
				time.Sleep(2 * time.Second) // slow down guessing
				http.Error(w, "wrong token", http.StatusUnauthorized)
				return
			}
			h(w, r)
		}
		mux.HandleFunc(path, guarded)
		public.HandleFunc(path, guarded)
	}
	api("/api/status", b.apiStatus)
	api("/api/pair/qr", b.qrPNG)
	api("/api/pair/unlink", b.apiUnlink)
	api("/api/assets", b.assets.apiList)
	api("/api/assets/file", b.assets.apiFile)
	api("/api/chats", b.apiChats)
	api("/api/messages", b.apiMessages)
	api("/api/updates", b.apiUpdates)
	api("/api/send", b.apiSend)
	api("/api/read", b.apiRead)
	api("/api/react", b.apiReact)
	api("/api/media", b.apiMedia)
	api("/api/sendvoice", b.apiSendVoice)
	api("/api/sendimage", b.apiSendImage)
	api("/api/sendvideo", b.apiSendVideo)
	api("/api/avatar", b.apiAvatar)
	api("/api/presence", b.apiPresence)
	api("/api/chatinfo", b.apiChatInfo)
	api("/api/contactinfo", b.apiContactInfo)
	api("/api/chatmedia", b.apiChatMedia)
	api("/api/mute", b.apiMute)
	api("/api/chat/delete", b.apiDeleteChat)
	api("/api/broadcasts", b.apiBroadcasts)
	api("/api/broadcast/send", b.apiBroadcastSend)
	api("/api/broadcast/resend", b.apiBroadcastResend)
	api("/api/me", b.apiMe)
	api("/api/me/name", b.apiSetName)
	api("/api/me/about", b.apiSetAbout)
	api("/api/me/photo", b.apiSetPhoto)
	api("/api/me/lastseen", b.apiSetLastSeen)
	api("/api/contacts", b.apiContacts)
	api("/api/blocklist", b.apiBlocklist)
	api("/api/group/create", b.apiCreateGroup)
	api("/api/group/photo", b.apiGroupPhoto)
	api("/api/group/subject", b.apiGroupSubject)
	api("/api/group/participants", b.apiGroupParticipants)
	api("/api/group/leave", b.apiGroupLeave)
	api("/api/calls", b.calls.apiList)
	api("/api/call/state", b.calls.apiState)
	api("/api/call/start", b.calls.apiStart)
	api("/api/call/answer", b.calls.apiAnswer)
	api("/api/call/hangup", b.calls.apiHangup)
	api("/api/call/audio", b.calls.apiAudio)
	api("/api/call/video", b.calls.apiVideo)
	api("/api/call/camera", b.calls.apiCamera)
	api("/api/call/orientation", b.calls.apiOrientation)
	api("/api/debug/incoming", b.apiDebugIncoming)
	api("/api/debug/clear", b.apiDebugClear)
	api("/api/debug/call", b.calls.apiDebugCall)
	api("/api/debug/appstate", b.apiDebugAppState)
	api("/api/diag", b.apiDiag)
	api("/api/chunk", b.apiChunk)

	if *tlsListen != "" {
		srv, fingerprint, err := tlsServer(*dataDir, *tlsListen, public)
		if err != nil {
			log.Fatal(err)
		}
		log.Printf("TLS listening on %s (certificate SHA-256 %s)", *tlsListen, fingerprint)
		go func() { log.Fatal(srv.ListenAndServeTLS("", "")) }()
	}
	log.Printf("listening on %s", *listen)
	// repo bypasses the mux, flat sources request /repo/./Packages and the mux would 307 it
	// (old apt doesn't follow redirects)
	home := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/repo/") {
			b.admin.repo.serve(w, r)
			return
		}
		mux.ServeHTTP(w, r)
	})
	log.Fatal(http.ListenAndServe(*listen, home))
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(v)
}

func httpErr(w http.ResponseWriter, err error, code int) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
}

func (b *Bridge) apiStatus(w http.ResponseWriter, r *http.Request) {
	out := map[string]any{
		"version":   version,
		"paired":    b.cli.Store.ID != nil,
		"connected": b.cli.IsConnected(),
		"loggedIn":  b.cli.IsLoggedIn(),
		"upd":       b.store.upd.Load(),
		// for the app's diagnostics (only sent if the user said yes)
		"platform": runtime.GOOS,
		"arch":     runtime.GOARCH,
		"kernel":   kernelRelease(),
		"docker":   fileExists("/.dockerenv"),
	}
	if id := b.cli.Store.ID; id != nil {
		out["jid"] = id.ToNonAD().String()
		out["pushName"] = b.cli.Store.PushName
	}
	// keeps the app's away address + pin up to date
	if away := b.admin.awayURL(); away != "" {
		out["awayURL"], out["pin"] = away, b.admin.setup.pin()
	}
	writeJSON(w, out)
}

func (b *Bridge) apiChats(w http.ResponseWriter, r *http.Request) {
	chats, err := b.store.Chats()
	if err != nil {
		httpErr(w, err, 500)
		return
	}
	ctx := r.Context()
	for i := range chats {
		jid, _ := types.ParseJID(chats[i].JID)
		chats[i].Group = jid.Server == types.GroupServer
		chats[i].Muted = b.mutedUntil(ctx, jid) != 0
		if chats[i].Name == "" {
			chats[i].Name = b.displayName(ctx, jid)
		}
		if chats[i].Group && !chats[i].LastFromMe && chats[i].LastSender != "" {
			sender, _ := types.ParseJID(chats[i].LastSender)
			chats[i].LastSenderName = b.displayName(ctx, sender)
		}
	}
	if chats == nil {
		chats = []Chat{}
	}
	writeJSON(w, map[string]any{"chats": chats, "upd": b.store.upd.Load()})
}

func (b *Bridge) withNames(ctx context.Context, msgs []Message) []Message {
	if msgs == nil {
		return []Message{}
	}
	b.store.addReactions(msgs)
	cache := map[string]string{}
	nameOf := func(sender string) string {
		n, ok := cache[sender]
		if !ok {
			jid, _ := types.ParseJID(sender)
			n = b.displayName(ctx, jid)
			cache[sender] = n
		}
		return n
	}
	for i := range msgs {
		if q := msgs[i].Quote; q != nil && !q.FromMe {
			q.Name = nameOf(q.Sender)
		}
		for j := range msgs[i].Reactions {
			if r := &msgs[i].Reactions[j]; !r.FromMe {
				r.Name = nameOf(r.Sender)
			}
		}
	}
	for i := range msgs {
		if msgs[i].FromMe {
			continue
		}
		cn, ok := cache["chat:"+msgs[i].Chat]
		if !ok {
			if cn = b.store.ChatName(msgs[i].Chat); cn == "" {
				jid, _ := types.ParseJID(msgs[i].Chat)
				cn = b.displayName(ctx, jid)
			}
			cache["chat:"+msgs[i].Chat] = cn
		}
		msgs[i].ChatName = cn
	}
	for i := range msgs {
		if msgs[i].FromMe || !strings.HasSuffix(msgs[i].Chat, "@"+types.GroupServer) {
			continue
		}
		n, ok := cache[msgs[i].Sender]
		if !ok {
			jid, _ := types.ParseJID(msgs[i].Sender)
			n = b.displayName(ctx, jid)
			cache[msgs[i].Sender] = n
		}
		msgs[i].Name = n
	}
	return msgs
}

func (b *Bridge) apiMessages(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	before, _ := strconv.ParseInt(q.Get("before"), 10, 64)
	limit, _ := strconv.Atoi(q.Get("limit"))
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	msgs, err := b.store.Messages(q.Get("chat"), before, limit)
	if err != nil {
		httpErr(w, err, 500)
		return
	}
	writeJSON(w, map[string]any{"messages": b.withNames(r.Context(), msgs)})
}

// apiUpdates is a long poll, returns when something changed after since or after wait secs.
func (b *Bridge) apiUpdates(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	since, _ := strconv.ParseInt(q.Get("since"), 10, 64)
	wait, _ := strconv.Atoi(q.Get("wait"))
	// 25s in the app, up to 15 min for the bg voip socket
	if wait < 0 || wait > 900 {
		wait = 25
	}
	incomingOnly := q.Get("only") == "incoming"
	deadline := time.After(time.Duration(wait) * time.Second)
	for {
		ch := b.store.waitChan()
		msgs, err := b.store.Updates(since, 200)
		if err != nil {
			httpErr(w, err, 500)
			return
		}
		chatsChanged := b.store.ChatsChangedSince(since)
		presence := b.presenceSince(since)
		call := b.calls.changedSince(since)
		if incomingOnly {
			// bg: ringing or missed call
			if call != nil && !(call.Incoming && (call.State == "ringing" ||
				call.State == "ended" && call.Since == 0 && call.Reason != "local")) {
				call = nil
			}
			// bg: only new incoming messages, not muted
			kept := msgs[:0]
			for _, m := range msgs {
				// created > since, reactions bump old messages
				if !m.FromMe && m.Created > since && !b.isMuted(r.Context(), m.Chat) {
					kept = append(kept, m)
				}
			}
			msgs, chatsChanged, presence = kept, false, nil
		}
		if len(msgs) > 0 || chatsChanged || len(presence) > 0 || call != nil || wait == 0 {
			upd := b.store.upd.Load()
			if len(msgs) == 200 {
				upd = msgs[len(msgs)-1].Upd
			}
			writeJSON(w, map[string]any{"messages": b.withNames(r.Context(), msgs), "chatsChanged": chatsChanged,
				"presence": presence, "call": call, "upd": upd, "unreadTotal": b.store.UnreadTotal()})
			return
		}
		select {
		case <-ch:
		case <-deadline:
			writeJSON(w, map[string]any{"messages": []Message{}, "chatsChanged": false, "upd": since,
				"unreadTotal": b.store.UnreadTotal()})
			return
		case <-r.Context().Done():
			return
		}
	}
}

func (b *Bridge) apiSend(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	chat, text := r.FormValue("chat"), r.FormValue("text")
	if chat == "" || strings.TrimSpace(text) == "" {
		http.Error(w, "chat and text needed", http.StatusBadRequest)
		return
	}
	sendText := func() (*Message, error) { return b.sendText(r.Context(), chat, text, r.FormValue("quote")) }
	if chat == testChat {
		sendText = func() (*Message, error) { return b.sendTest(text) }
	}
	m, err := sendText()
	if err != nil {
		httpErr(w, err, 502)
		return
	}
	writeJSON(w, m)
}

func (b *Bridge) apiRead(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	if err := b.markRead(r.Context(), r.FormValue("chat")); err != nil {
		httpErr(w, err, 502)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

// apiMedia downloads an attachment and returns it as is.
func (b *Bridge) apiMedia(w http.ResponseWriter, r *http.Request) {
	seq, _ := strconv.ParseInt(r.URL.Query().Get("seq"), 10, 64)
	_, _, raw, err := b.store.Raw(seq)
	if err != nil || len(raw) == 0 {
		http.NotFound(w, r)
		return
	}
	var msg waE2E.Message
	if err := proto.Unmarshal(raw, &msg); err != nil {
		httpErr(w, err, 500)
		return
	}
	var dl whatsmeow.DownloadableMessage
	var mime string
	switch {
	case msg.GetImageMessage() != nil:
		dl, mime = msg.GetImageMessage(), msg.GetImageMessage().GetMimetype()
	case msg.GetVideoMessage() != nil:
		dl, mime = msg.GetVideoMessage(), msg.GetVideoMessage().GetMimetype()
	case msg.GetPtvMessage() != nil:
		dl, mime = msg.GetPtvMessage(), msg.GetPtvMessage().GetMimetype()
	case msg.GetAudioMessage() != nil:
		dl, mime = msg.GetAudioMessage(), msg.GetAudioMessage().GetMimetype()
	case msg.GetStickerMessage() != nil:
		dl, mime = msg.GetStickerMessage(), msg.GetStickerMessage().GetMimetype()
	case msg.GetDocumentMessage() != nil:
		dl, mime = msg.GetDocumentMessage(), msg.GetDocumentMessage().GetMimetype()
	default:
		http.NotFound(w, r)
		return
	}
	if r.URL.Query().Get("format") == "thumb" { // thumbnail for all media
		thumb := msg.GetImageMessage().GetJPEGThumbnail()
		if thumb == nil {
			thumb = msg.GetVideoMessage().GetJPEGThumbnail()
		}
		if thumb == nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "image/jpeg")
		w.Write(thumb)
		return
	}
	if format := r.URL.Query().Get("format"); format == "mp4" || format == "poster" {
		if msg.GetVideoMessage() == nil && msg.GetPtvMessage() == nil {
			httpErr(w, errNotVideo, 400)
			return
		}
		b.serveVideo(w, r, seq, dl, format == "poster")
		return
	}
	if msg.GetAudioMessage() != nil && r.URL.Query().Get("format") == "m4a" {
		b.serveAudioM4A(w, r, seq, dl)
		return
	}
	data, err := b.cli.Download(r.Context(), dl)
	if err != nil {
		httpErr(w, err, 502)
		return
	}
	w.Header().Set("Content-Type", mime)
	w.Write(data)
}

// qrPNG is the pairing qr for the app (needs the key).
func (b *Bridge) qrPNG(w http.ResponseWriter, r *http.Request) {
	if b.cli.Store.ID != nil {
		http.Error(w, "already paired", http.StatusGone)
		return
	}
	code := b.currentQR()
	if code == "" {
		http.Error(w, "waiting for a code", http.StatusServiceUnavailable)
		return
	}
	png, err := qrcode.Encode(code, qrcode.Medium, 512)
	if err != nil {
		httpErr(w, err, 500)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(png)
}

// e.g. 6.10.14-linuxkit (docker desktop) or 6.1.0-rpi7-rpi-v8, says where the bridge runs
func kernelRelease() string {
	b, err := os.ReadFile("/proc/sys/kernel/osrelease")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
