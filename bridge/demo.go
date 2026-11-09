package main

import (
	"embed"
	"fmt"
	"log"
	"net/http"
	"sort"
	"strconv"
	"sync"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

// Demo mode (-demo): fake english chats for screenshots, no whatsapp, any key works.
// Pics from tools/make_demo_assets.py.

//go:embed demo/*.jpg
var demoFiles embed.FS

type demoContact struct {
	jid, name, phone, about, avatar string
	group                           bool
	members                         []string // members
}

type demoServer struct {
	mu       sync.Mutex
	contacts []demoContact
	msgs     map[string][]Message
	seq      int64
	start    time.Time
	call     *CallInfo     // fake call
	callWake chan struct{} // closed on change to wake long polls
	setupAt  time.Time     // setup screenshots: qr for a while after the code, then "paired"
}

const demoMe = "15550100@s.whatsapp.net"

func runDemo(listen string) {
	d := &demoServer{msgs: map[string][]Message{}, start: time.Now(), callWake: make(chan struct{})}
	d.build()
	mux := http.NewServeMux()
	j := func(path string, h func(r *http.Request) any) {
		mux.HandleFunc(path, func(w http.ResponseWriter, r *http.Request) { writeJSON(w, h(r)) })
	}
	ok := func(*http.Request) any { return map[string]bool{"ok": true} }
	j("/api/status", func(*http.Request) any {
		return map[string]any{"version": version, "paired": true, "connected": true, "loggedIn": true, "upd": d.seq, "jid": demoMe, "pushName": "Alex Carter"}
	})
	j("/api/chats", func(*http.Request) any { return map[string]any{"chats": d.chats(), "upd": d.seq} })
	j("/api/calls", func(*http.Request) any { return map[string]any{"calls": d.callLog()} })
	j("/api/messages", func(r *http.Request) any {
		if r.URL.Query().Get("before") != "" && r.URL.Query().Get("before") != "0" {
			return map[string]any{"messages": []Message{}}
		}
		d.mu.Lock()
		defer d.mu.Unlock()
		return map[string]any{"messages": append([]Message{}, d.msgs[r.URL.Query().Get("chat")]...)}
	})
	mux.HandleFunc("/api/updates", func(w http.ResponseWriter, r *http.Request) {
		wait, _ := strconv.Atoi(r.URL.Query().Get("wait"))
		if wait > 25 {
			wait = 25
		}
		d.mu.Lock()
		wake := d.callWake
		d.mu.Unlock()
		select {
		case <-time.After(time.Duration(wait) * time.Second):
		case <-wake:
		case <-r.Context().Done():
			return
		}
		since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
		d.mu.Lock()
		call := d.call
		d.mu.Unlock()
		writeJSON(w, map[string]any{"messages": []Message{}, "chatsChanged": false, "upd": since, "unreadTotal": d.unread(), "call": call})
	})
	j("/api/send", func(r *http.Request) any {
		d.mu.Lock()
		defer d.mu.Unlock()
		d.seq++
		m := Message{Seq: d.seq, ID: "demo" + strconv.FormatInt(d.seq, 10), Chat: r.FormValue("chat"), Sender: demoMe,
			FromMe: true, TS: time.Now().Unix(), Kind: "text", Text: r.FormValue("text"), Status: statusRead, Upd: d.seq}
		d.msgs[m.Chat] = append(d.msgs[m.Chat], m)
		return m
	})
	for _, p := range []string{"/api/read", "/api/presence", "/api/mute", "/api/me/name", "/api/me/about", "/api/me/lastseen"} {
		j(p, ok)
	}
	mux.HandleFunc("/api/avatar", func(w http.ResponseWriter, r *http.Request) {
		jid := r.URL.Query().Get("jid")
		name := "me"
		if jid != demoMe {
			c := d.contact(jid)
			if c == nil || c.avatar == "" {
				http.NotFound(w, r)
				return
			}
			name = c.avatar
		}
		data, _ := demoFiles.ReadFile("demo/avatar-" + name + ".jpg")
		w.Header().Set("Content-Type", "image/jpeg")
		w.Write(data)
	})
	mux.HandleFunc("/api/media", func(w http.ResponseWriter, r *http.Request) {
		file := "demo/photo-sunset.jpg"
		if r.URL.Query().Get("format") == "thumb" {
			file = "demo/photo-sunset-thumb.jpg"
		}
		data, _ := demoFiles.ReadFile(file)
		w.Header().Set("Content-Type", "image/jpeg")
		w.Write(data)
	})
	j("/api/chatinfo", func(r *http.Request) any {
		c := d.contact(r.URL.Query().Get("chat"))
		if c == nil {
			return map[string]any{}
		}
		out := map[string]any{"chat": c.jid}
		if !c.group {
			out["mutedUntil"] = 0
			out["presence"] = Presence{Chat: c.jid, LastSeen: time.Now().Add(-12 * time.Minute).Unix()}
			return out
		}
		var names []string
		var parts []participant
		for i, m := range c.members {
			mc := d.contact(m)
			names = append(names, firstName(mc.name))
			parts = append(parts, participant{JID: m, Name: mc.name, Phone: mc.phone, About: mc.about, Admin: i == 0})
		}
		sort.Strings(names)
		parts = append(parts, participant{JID: demoMe, Name: "You", Me: true})
		out["members"], out["name"], out["participants"] = append(names, "You"), c.name, parts
		out["topic"] = ""
		out["created"] = d.start.AddDate(0, -3, 0).Unix()
		return out
	})
	j("/api/contactinfo", func(r *http.Request) any {
		c := d.contact(r.URL.Query().Get("jid"))
		if c == nil {
			return map[string]any{}
		}
		return map[string]any{"jid": c.jid, "name": c.name, "phone": c.phone, "about": c.about, "mutedUntil": 0, "media": 0,
			"presence": Presence{Chat: c.jid, LastSeen: time.Now().Add(-12 * time.Minute).Unix()}}
	})
	j("/api/chatmedia", func(r *http.Request) any {
		var items []MediaItem
		d.mu.Lock()
		for _, m := range d.msgs[r.URL.Query().Get("chat")] {
			if m.Kind == "image" {
				items = append(items, MediaItem{Seq: m.Seq, Kind: m.Kind, TS: m.TS, FromMe: m.FromMe})
			}
		}
		d.mu.Unlock()
		if items == nil {
			items = []MediaItem{}
		}
		return map[string]any{"media": items}
	})
	j("/api/me", func(*http.Request) any {
		return map[string]any{"jid": demoMe, "phone": "+1 555-0100", "pushName": "Alex Carter", "device": 12, "connected": true,
			"platform": "WA Classic (linked device)", "about": "Hey there! I am using WA Classic.", "lastSeen": "all", "readReceipts": "all"}
	})
	j("/api/contacts", func(*http.Request) any {
		var list []contact
		for _, c := range d.contacts {
			if !c.group {
				list = append(list, contact{JID: c.jid, Name: c.name, Phone: c.phone, About: c.about})
			}
		}
		sort.Slice(list, func(i, k int) bool { return list[i].Name < list[k].Name })
		return map[string]any{"contacts": list, "me": "+1 555-0100"}
	})
	j("/api/blocklist", func(*http.Request) any { return map[string]any{"blocked": []string{}} })
	// fake call: /api/debug/call?name=Emma Wilson, state=ended hangs up. no audio
	state := func(*http.Request) any {
		d.mu.Lock()
		defer d.mu.Unlock()
		if d.call == nil {
			return map[string]any{}
		}
		return *d.call
	}
	j("/api/call/state", state)
	mux.HandleFunc("/api/debug/call", func(w http.ResponseWriter, r *http.Request) {
		name := r.FormValue("name")
		if name == "" {
			name = "Emma Wilson"
		}
		peer := "15550101@s.whatsapp.net"
		for _, c := range d.contacts {
			if c.name == name {
				peer = c.jid
			}
		}
		if r.FormValue("state") == "ended" {
			d.setCall(func(c *CallInfo) { c.State, c.Reason = "ended", "remote" })
		} else {
			d.mu.Lock()
			d.call = &CallInfo{ID: fmt.Sprintf("DEMOCALL%d", time.Now().UnixNano()), Peer: peer, Name: name, Incoming: true, State: "ringing"}
			d.mu.Unlock()
			d.setCall(func(*CallInfo) {})
		}
		writeJSON(w, state(r))
	})
	mux.HandleFunc("/api/call/answer", func(w http.ResponseWriter, r *http.Request) {
		d.setCall(func(c *CallInfo) { c.State, c.Since = "active", time.Now().Unix() })
		writeJSON(w, state(r))
	})
	mux.HandleFunc("/api/call/hangup", func(w http.ResponseWriter, r *http.Request) {
		d.setCall(func(c *CallInfo) { c.State, c.Reason = "ended", "local" })
		writeJSON(w, state(r))
	})
	mux.HandleFunc("/api/pair/qr", func(w http.ResponseWriter, r *http.Request) {
		d.mu.Lock()
		since := time.Since(d.setupAt)
		d.mu.Unlock()
		switch {
		case since < 3*time.Second:
			http.Error(w, "waiting for a code", http.StatusServiceUnavailable)
		case since < 25*time.Second:
			png, err := qrcode.Encode("https://waclassic.com", qrcode.Medium, 512)
			if err != nil {
				httpErr(w, err, 500)
				return
			}
			w.Header().Set("Content-Type", "image/png")
			w.Write(png)
		default:
			http.Error(w, "already paired", http.StatusGone)
		}
	})
	j("/api/setup", func(*http.Request) any {
		d.mu.Lock()
		d.setupAt = time.Now()
		d.mu.Unlock()
		return map[string]string{"token": "demo"}
	})
	log.Printf("demo mode: made-up chats on %s (any key works)", listen)
	log.Fatal(http.ListenAndServe(listen, mux))
}

func (d *demoServer) contact(jid string) *demoContact {
	for i := range d.contacts {
		if d.contacts[i].jid == jid {
			return &d.contacts[i]
		}
	}
	return nil
}

func (d *demoServer) unread() int {
	n := 0
	for _, c := range d.chats() {
		n += c.Unread
	}
	return n
}

func (d *demoServer) chats() []Chat {
	d.mu.Lock()
	defer d.mu.Unlock()
	var out []Chat
	for _, c := range d.contacts {
		msgs := d.msgs[c.jid]
		if len(msgs) == 0 {
			continue
		}
		last := msgs[len(msgs)-1]
		ch := Chat{JID: c.jid, Name: c.name, LastTS: last.TS, LastText: last.Text, Group: c.group, LastKind: last.Kind,
			LastFromMe: last.FromMe, LastStatus: last.Status, LastSecs: last.Secs}
		for _, m := range msgs {
			if !m.FromMe && m.Status == 0 && m.Kind != "system" {
				ch.Unread++
			}
		}
		if c.group && !last.FromMe {
			ch.LastSenderName = firstName(d.contact(last.Sender).name)
		}
		out = append(out, ch)
	}
	sort.Slice(out, func(i, k int) bool { return out[i].LastTS > out[k].LastTS })
	return out
}

// build creates contacts + chats relative to now.
func (d *demoServer) build() {
	p := func(id, name, phone, about, avatar string) demoContact {
		return demoContact{jid: id + "@s.whatsapp.net", name: name, phone: phone, about: about, avatar: avatar}
	}
	d.contacts = []demoContact{
		p("15550101", "Emma Wilson", "+1 555-0101", "Coffee first ☕️", "emma"),
		p("15550102", "Jake Miller", "+1 555-0102", "At the gym", "jake"),
		p("15550103", "Olivia Brown", "+1 555-0103", "Available", "olivia"),
		p("15550104", "Daniel Lee", "+1 555-0104", "Busy", "daniel"),
		p("15550105", "Sophie Martin", "+1 555-0105", "Hey there! I am using WhatsApp.", "sophie"),
		p("15550106", "Mom", "+1 555-0106", "Family is everything ❤️", "mom"),
		p("15550107", "Liam Turner", "+1 555-0107", "Urgent calls only", "liam"),
		{jid: "120363000000000001@g.us", name: "Family", avatar: "family", group: true,
			members: []string{"15550106@s.whatsapp.net", "15550107@s.whatsapp.net"}},
		{jid: "120363000000000002@g.us", name: "Weekend Trip 🏔", avatar: "trip", group: true,
			members: []string{"15550101@s.whatsapp.net", "15550102@s.whatsapp.net", "15550104@s.whatsapp.net"}},
		{jid: "120363000000000003@g.us", name: "Book Club", avatar: "bookclub", group: true,
			members: []string{"15550103@s.whatsapp.net", "15550105@s.whatsapp.net"}},
	}
	now := time.Now()
	day := func(daysAgo, hour, min int) int64 {
		t := now.AddDate(0, 0, -daysAgo)
		return time.Date(t.Year(), t.Month(), t.Day(), hour, min, 0, 0, t.Location()).Unix()
	}
	// nothing in the future
	today := func(minutesAgo int) int64 { return now.Add(-time.Duration(minutesAgo) * time.Minute).Unix() }
	add := func(chat, sender string, ts int64, kind, text string, status, secs int) {
		d.seq++
		fromMe := sender == ""
		if fromMe {
			sender = demoMe
		}
		d.msgs[chat] = append(d.msgs[chat], Message{Seq: d.seq, ID: "demo" + strconv.FormatInt(d.seq, 10), Chat: chat,
			Sender: sender, FromMe: fromMe, TS: ts, Kind: kind, Text: text, Status: status, Secs: secs, Upd: d.seq})
	}
	const read, seen, unread = statusRead, 1, 0
	emma, jake, olivia := "15550101@s.whatsapp.net", "15550102@s.whatsapp.net", "15550103@s.whatsapp.net"
	daniel, sophie, mom, liam := "15550104@s.whatsapp.net", "15550105@s.whatsapp.net", "15550106@s.whatsapp.net", "15550107@s.whatsapp.net"
	family, trip, books := "120363000000000001@g.us", "120363000000000002@g.us", "120363000000000003@g.us"

	add(emma, emma, day(1, 18, 2), "text", "Are we still on for dinner tomorrow?", seen, 0)
	add(emma, "", day(1, 18, 10), "text", "Of course! The new Italian place?", read, 0)
	add(emma, emma, day(1, 18, 11), "text", "Yes! I heard their pizza is amazing 🍕", seen, 0)
	add(emma, "", today(52), "text", "I booked a table for 7:30", read, 0)
	add(emma, emma, today(49), "text", "Perfect, thank you!", seen, 0)
	add(emma, emma, today(48), "text", "Should I bring anything?", seen, 0)
	add(emma, "", today(45), "text", "Just yourself 😊", read, 0)
	add(emma, emma, today(6), "text", "See you at 7:30 then!", unread, 0)

	add(trip, jake, day(2, 20, 15), "text", "Who's bringing the tent?", seen, 0)
	add(trip, "", day(2, 20, 21), "text", "I have one for four people", read, 0)
	add(trip, daniel, day(2, 20, 25), "text", "Great, I'll bring snacks and the speaker", seen, 0)
	add(trip, emma, today(80), "image", "Look at this view from last year!", seen, 0)
	add(trip, jake, today(14), "text", "Can't wait for Saturday 🙌", unread, 0)
	add(trip, daniel, today(13), "text", "Leaving at 8 sharp!", unread, 0)

	add(family, mom, today(150), "text", "Dinner on Sunday at our place?", seen, 0)
	add(family, liam, today(140), "text", "I'm in!", seen, 0)
	add(family, "", today(130), "text", "Sounds great, I'll bring dessert", read, 0)
	add(family, mom, today(25), "text", "Don't forget to call grandma, it's her birthday 🎂", unread, 0)

	add(jake, jake, day(1, 21, 40), "text", "Did you see the game last night?", seen, 0)
	add(jake, "", day(1, 21, 45), "text", "That last minute goal! ⚽️", read, 0)
	add(jake, jake, today(200), "audio", "", seen, 14)

	add(olivia, olivia, day(1, 9, 30), "text", "Thanks again for helping me move yesterday", seen, 0)
	add(olivia, "", day(1, 9, 41), "text", "Anytime! The new apartment looks great", read, 0)
	add(olivia, olivia, day(1, 9, 42), "text", "Housewarming party next Friday, you have to come!", seen, 0)
	add(olivia, "", day(1, 9, 50), "text", "Wouldn't miss it 🎉", read, 0)

	add(books, olivia, day(2, 19, 0), "text", "Next book: \"The Midnight Library\"?", seen, 0)
	add(books, sophie, day(2, 19, 4), "text", "Yes please, I heard it's wonderful", seen, 0)
	add(books, "", day(2, 19, 10), "text", "Count me in 📚", read, 0)

	add(daniel, "", day(3, 12, 5), "text", "Lunch next week?", read, 0)
	add(daniel, daniel, day(3, 12, 30), "text", "Sure, Tuesday works for me", seen, 0)

	add(sophie, sophie, day(5, 16, 20), "call", "missed", seen, 0)
	add(sophie, "", day(5, 16, 35), "text", "Sorry I missed your call, I'll call you back later!", read, 0)

	add(liam, liam, day(6, 10, 0), "text", "Happy birthday! 🎈 Have a great day", seen, 0)
	add(liam, "", day(6, 10, 12), "text", "Thank you so much!", read, 0)
}

// callLog: made up calls tab, not in the chats so old screenshots stay the same.
func (d *demoServer) callLog() []CallEntry {
	now := time.Now()
	calls := []CallEntry{}
	add := func(jid, name string, ago time.Duration, fromMe bool, text string, secs int) {
		calls = append(calls, CallEntry{ID: "democall" + strconv.Itoa(len(calls)), Peer: jid, Name: name, FromMe: fromMe,
			TS: now.Add(-ago).Unix(), Text: text, Secs: secs})
	}
	add("15550101@s.whatsapp.net", "Emma Wilson", 12*time.Minute, true, "answered", 245)
	add("15550105@s.whatsapp.net", "Sophie Martin", 95*time.Minute, false, "missed", 0)
	add("15550105@s.whatsapp.net", "Sophie Martin", 110*time.Minute, false, "missed", 0)
	add("15550102@s.whatsapp.net", "Jake Miller", 5*time.Hour, false, "answered", 62)
	add("15550106@s.whatsapp.net", "Mom", 26*time.Hour, true, "unanswered", 0)
	add("15550104@s.whatsapp.net", "Daniel Lee", 30*time.Hour, false, "declined", 0)
	add("15550103@s.whatsapp.net", "Olivia Brown", 3*24*time.Hour, true, "answered", 1340)
	add("15550107@s.whatsapp.net", "Liam Turner", 6*24*time.Hour, false, "elsewhere", 0)
	return calls
}

// setCall updates the fake call and wakes long polls.
func (d *demoServer) setCall(change func(*CallInfo)) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.call == nil {
		return
	}
	d.seq++
	change(d.call)
	d.call.Upd = d.seq
	close(d.callWake)
	d.callWake = make(chan struct{})
}
