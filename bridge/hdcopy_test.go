package main

import (
	"path/filepath"
	"testing"

	"github.com/polymorfa/hypermeow/proto/waCommon"
	"github.com/polymorfa/hypermeow/proto/waE2E"
	"github.com/polymorfa/hypermeow/types"
	"github.com/polymorfa/hypermeow/types/events"
	"google.golang.org/protobuf/proto"
)

func childEvent(id string, kind waE2E.MessageAssociation_AssociationType, child *waE2E.Message) *events.Message {
	raw := &waE2E.Message{
		AssociatedChildMessage: &waE2E.FutureProofMessage{Message: child},
		MessageContextInfo: &waE2E.MessageContextInfo{MessageAssociation: &waE2E.MessageAssociation{
			AssociationType:  kind.Enum(),
			ParentMessageKey: &waCommon.MessageKey{ID: proto.String("PARENT")},
		}},
	}
	return (&events.Message{Info: types.MessageInfo{ID: id}, RawMessage: raw}).UnwrapRaw()
}

func TestMessageIDForCopies(t *testing.T) {
	img := &waE2E.Message{ImageMessage: &waE2E.ImageMessage{Caption: proto.String("look")}}
	vid := &waE2E.Message{VideoMessage: &waE2E.VideoMessage{}}
	plain := (&events.Message{Info: types.MessageInfo{ID: "PARENT"}, RawMessage: img}).UnwrapRaw()
	cases := []struct {
		name string
		e    *events.Message
		want string
	}{
		{"plain", plain, "PARENT"},
		{"hd image", childEvent("HD", waE2E.MessageAssociation_HD_IMAGE_DUAL_UPLOAD, img), "PARENT"},
		{"hd video", childEvent("HDV", waE2E.MessageAssociation_HD_VIDEO_DUAL_UPLOAD, vid), "PARENT"},
		{"hevc video", childEvent("HEVC", waE2E.MessageAssociation_HEVC_VIDEO_DUAL_UPLOAD, vid), "PARENT"},
		{"motion photo", childEvent("MP", waE2E.MessageAssociation_MOTION_PHOTO, vid), ""},
		{"album", childEvent("ALB", waE2E.MessageAssociation_MEDIA_ALBUM, img), "ALB"},
	}
	for _, c := range cases {
		if got := messageID(c.e); got != c.want {
			t.Errorf("%s: id %q, want %q", c.name, got, c.want)
		}
	}
}

// hd copy before or after the normal photo: one message either way
func TestHDCopyStoredOnce(t *testing.T) {
	for _, hdFirst := range []bool{false, true} {
		db, err := openSQLite(filepath.Join(t.TempDir(), "wa4s.db"))
		if err != nil {
			t.Fatal(err)
		}
		s, err := openStore(db)
		if err != nil {
			t.Fatal(err)
		}
		chat := "1@s.whatsapp.net"
		hd := childEvent("HD", waE2E.MessageAssociation_HD_IMAGE_DUAL_UPLOAD,
			&waE2E.Message{ImageMessage: &waE2E.ImageMessage{Caption: proto.String("look")}})
		ids := []string{"PARENT", messageID(hd)}
		if hdFirst {
			ids[0], ids[1] = ids[1], ids[0]
		}
		var added []bool
		for _, id := range ids {
			ok, err := s.AddMessage(&Message{ID: id, Chat: chat, Sender: chat, TS: 1, Kind: "image", Text: "look"}, nil, true)
			if err != nil {
				t.Fatal(err)
			}
			added = append(added, ok)
		}
		if !added[0] || added[1] {
			t.Errorf("hdFirst=%v: added %v, want [true false]", hdFirst, added)
		}
	}
}
