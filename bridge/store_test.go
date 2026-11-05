package main

import (
	"path/filepath"
	"testing"
)

func TestReactionsAndQuotes(t *testing.T) {
	db, err := openSQLite(filepath.Join(t.TempDir(), "wa4s.db"))
	if err != nil {
		t.Fatal(err)
	}
	// pre-1.1 db, openStore adds the new columns
	if _, err := db.Exec(schema); err != nil {
		t.Fatal(err)
	}
	s, err := openStore(db)
	if err != nil {
		t.Fatal(err)
	}
	chat := "1@s.whatsapp.net"
	orig := &Message{ID: "A", Chat: chat, Sender: chat, TS: 1, Kind: "text", Text: "hello"}
	if _, err := s.AddMessage(orig, nil, true); err != nil {
		t.Fatal(err)
	}
	reply := &Message{ID: "B", Chat: chat, Sender: "2@s.whatsapp.net", FromMe: true, TS: 2, Kind: "text", Text: "hi",
		Quote: &Quote{ID: "A", Sender: chat, Kind: "text", Text: "hello"}}
	if _, err := s.AddMessage(reply, nil, false); err != nil {
		t.Fatal(err)
	}
	before := s.upd.Load()
	if !s.SetReaction(chat, "A", chat, false, "👍", 10) || !s.SetReaction(chat, "A", "2@s.whatsapp.net", true, "❤️", 11) {
		t.Fatal("reaction to a stored message not taken")
	}
	s.SetReaction(chat, "A", chat, false, "😂", 9) // older, ignored
	msgs, err := s.Updates(before, 10)
	if err != nil || len(msgs) != 1 || msgs[0].ID != "A" || msgs[0].Created > before {
		t.Fatalf("updates after a reaction: %+v %v", msgs, err)
	}
	all, _ := s.Messages(chat, 0, 10)
	s.addReactions(all)
	if len(all) != 2 || len(all[0].Reactions) != 2 || all[0].Reactions[0].Emoji != "👍" || !all[0].Reactions[1].FromMe {
		t.Fatalf("reactions: %+v", all[0].Reactions)
	}
	if q := all[1].Quote; q == nil || q.ID != "A" || q.Text != "hello" {
		t.Fatalf("quote: %+v", q)
	}
	s.SetReaction(chat, "A", chat, false, "", 12)
	all, _ = s.Messages(chat, 0, 10)
	s.addReactions(all)
	if len(all[0].Reactions) != 1 {
		t.Fatalf("removed reaction still there: %+v", all[0].Reactions)
	}
	if m, _, err := s.MessageByID(chat, "B"); err != nil || m.Quote == nil {
		t.Fatalf("message by id: %+v %v", m, err)
	}
	gone := s.upd.Load()
	if err := s.DeleteChat(chat); err != nil {
		t.Fatal(err)
	}
	if left, _ := s.Messages(chat, 0, 10); len(left) != 0 || !s.ChatsChangedSince(gone) {
		t.Fatalf("chat still there (%d messages) or not reported as changed", len(left))
	}
}

func TestBroadcasts(t *testing.T) {
	db, err := openSQLite(filepath.Join(t.TempDir(), "wa4s.db"))
	if err != nil {
		t.Fatal(err)
	}
	s, err := openStore(db)
	if err != nil {
		t.Fatal(err)
	}
	bc := &Broadcast{TS: 5, Kind: "text", Text: "hi all",
		Recipients: []BroadcastRecipient{{JID: "1@s.whatsapp.net", MsgID: "A"}, {JID: "2@s.whatsapp.net", MsgID: "B"}}}
	if err := s.AddBroadcast(bc); err != nil || bc.ID == 0 {
		t.Fatalf("add: %v %d", err, bc.ID)
	}
	list, err := s.Broadcasts()
	if err != nil || len(list) != 1 || len(list[0].Recipients) != 2 || list[0].Recipients[1].MsgID != "B" {
		t.Fatalf("list: %+v %v", list, err)
	}
	if err := s.DeleteBroadcast(bc.ID); err != nil {
		t.Fatal(err)
	}
	if list, _ := s.Broadcasts(); len(list) != 0 {
		t.Fatalf("still there: %+v", list)
	}
}
