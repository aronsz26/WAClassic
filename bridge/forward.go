package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"

	"github.com/polymorfa/hypermeow/proto/waE2E"
	"github.com/polymorfa/hypermeow/types"
	"google.golang.org/protobuf/proto"
)

var errCannotForward = errors.New("this message cannot be forwarded")

func (b *Bridge) apiForwardMessage(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	sourceChat, messageID, targetChat := r.FormValue("source_chat"), r.FormValue("message_id"), r.FormValue("target_chat")
	seq := int64(0)
	if rawSeq := r.FormValue("message_seq"); rawSeq != "" {
		var err error
		seq, err = strconv.ParseInt(rawSeq, 10, 64)
		if err != nil || seq <= 0 {
			httpErr(w, errors.New("invalid message sequence"), http.StatusBadRequest)
			return
		}
	}
	if sourceChat == "" || (messageID == "" && seq == 0) || targetChat == "" {
		httpErr(w, errors.New("source_chat, message_id or message_seq, and target_chat needed"), http.StatusBadRequest)
		return
	}
	msg, err := b.forwardMessage(r.Context(), sourceChat, messageID, seq, targetChat)
	if err != nil {
		status := http.StatusBadGateway
		if errors.Is(err, errCannotForward) {
			status = http.StatusBadRequest
		} else if err == errMessageNotFound {
			status = http.StatusNotFound
		}
		httpErr(w, err, status)
		return
	}
	writeJSON(w, msg)
}

var errMessageNotFound = errors.New("message not found")

func (b *Bridge) forwardMessage(ctx context.Context, sourceChat, messageID string, seq int64, targetChat string) (*Message, error) {
	source, err := types.ParseJID(sourceChat)
	if err != nil || (source.Server != types.DefaultUserServer && source.Server != types.LegacyUserServer && source.Server != types.HiddenUserServer && source.Server != types.GroupServer) {
		return nil, errors.New("invalid source chat")
	}
	target, err := types.ParseJID(targetChat)
	if err != nil || (target.Server != types.DefaultUserServer && target.Server != types.LegacyUserServer && target.Server != types.HiddenUserServer && target.Server != types.GroupServer) {
		return nil, errors.New("invalid destination chat")
	}
	// The app can hold an LID JID while the bridge stores the same conversation
	// under its phone-number JID. Resolve both sides with the same mapping used
	// when messages are stored before looking up the source row.
	source = b.chatKey(ctx, source).ToNonAD()
	target = b.chatKey(ctx, target).ToNonAD()
	var stored *Message
	var raw []byte
	if seq > 0 {
		stored, raw, err = b.store.MessageBySeq(seq)
		if err == nil && messageID != "" && stored.ID != messageID {
			err = errors.New("stale message sequence")
		}
	}
	if err != nil && messageID != "" {
		stored, raw, err = b.store.MessageByID(source.String(), messageID)
		if err != nil {
			stored, raw, err = b.store.MessageByIDAnyChat(messageID)
		}
	}
	if err != nil {
		return nil, errMessageNotFound
	}
	if stored.Kind == "view-once-photo" || stored.Kind == "view-once-video" || stored.Kind == "view-once-media" || stored.Kind == "call" || stored.Kind == "system" {
		return nil, errCannotForward
	}

	forwarded := &waE2E.Message{}
	if len(raw) != 0 {
		if err := proto.Unmarshal(raw, forwarded); err != nil {
			return nil, fmt.Errorf("could not read original message: %w", err)
		}
	} else if stored.Kind == "text" {
		forwarded.Conversation = proto.String(stored.Text)
	} else {
		return nil, errCannotForward
	}
	if !forwardableKind(stored.Kind) || !markForwarded(forwarded) {
		return nil, errCannotForward
	}

	resp, err := b.cli.SendMessage(ctx, target, forwarded)
	if err != nil {
		return nil, err
	}
	var forwardedRaw []byte
	if stored.Kind != "text" {
		forwardedRaw, err = proto.Marshal(forwarded)
		if err != nil {
			return nil, err
		}
	}
	sent := &Message{
		ID: resp.ID, Chat: target.String(), Sender: b.ownJID().String(), FromMe: true,
		TS: unix(resp.Timestamp), Kind: stored.Kind, Text: stored.Text, Status: statusSent, Secs: stored.Secs,
	}
	if _, err := b.store.AddMessage(sent, forwardedRaw, false); err != nil {
		return nil, err
	}
	b.store.notify()
	return sent, nil
}

func forwardableKind(kind string) bool {
	switch kind {
	case "text", "image", "video", "audio", "sticker", "document", "location", "contact":
		return true
	default:
		return false
	}
}

func markForwarded(msg *waE2E.Message) bool {
	if msg.GetViewOnceMessage() != nil || msg.GetViewOnceMessageV2() != nil || msg.GetViewOnceMessageV2Extension() != nil {
		return false
	}
	// Conversation has no ContextInfo; use ExtendedTextMessage so WhatsApp can
	// display its forwarded marker and keep forwarding metadata with the text.
	if msg.GetConversation() != "" {
		text := msg.GetConversation()
		msg.Conversation = nil
		msg.ExtendedTextMessage = &waE2E.ExtendedTextMessage{Text: proto.String(text), ContextInfo: &waE2E.ContextInfo{}}
	}
	ci := ensureForwardContext(msg)
	if ci == nil {
		return false
	}
	ci.StanzaID = nil
	ci.Participant = nil
	ci.RemoteJID = nil
	ci.QuotedMessage = nil
	ci.IsForwarded = proto.Bool(true)
	score := ci.GetForwardingScore() + 1
	if score == 0 {
		score = 1
	}
	ci.ForwardingScore = proto.Uint32(score)
	return true
}

func ensureForwardContext(msg *waE2E.Message) *waE2E.ContextInfo {
	if ci := contextOf(msg); ci != nil {
		return ci
	}
	switch {
	case msg.GetImageMessage() != nil:
		msg.ImageMessage.ContextInfo = &waE2E.ContextInfo{}
		return msg.ImageMessage.ContextInfo
	case msg.GetVideoMessage() != nil:
		msg.VideoMessage.ContextInfo = &waE2E.ContextInfo{}
		return msg.VideoMessage.ContextInfo
	case msg.GetPtvMessage() != nil:
		msg.PtvMessage.ContextInfo = &waE2E.ContextInfo{}
		return msg.PtvMessage.ContextInfo
	case msg.GetAudioMessage() != nil:
		msg.AudioMessage.ContextInfo = &waE2E.ContextInfo{}
		return msg.AudioMessage.ContextInfo
	case msg.GetStickerMessage() != nil:
		msg.StickerMessage.ContextInfo = &waE2E.ContextInfo{}
		return msg.StickerMessage.ContextInfo
	case msg.GetDocumentMessage() != nil:
		msg.DocumentMessage.ContextInfo = &waE2E.ContextInfo{}
		return msg.DocumentMessage.ContextInfo
	case msg.GetLocationMessage() != nil:
		msg.LocationMessage.ContextInfo = &waE2E.ContextInfo{}
		return msg.LocationMessage.ContextInfo
	case msg.GetContactMessage() != nil:
		msg.ContactMessage.ContextInfo = &waE2E.ContextInfo{}
		return msg.ContactMessage.ContextInfo
	case msg.GetDocumentWithCaptionMessage() != nil:
		return ensureForwardContext(msg.DocumentWithCaptionMessage.GetMessage())
	case msg.GetExtendedTextMessage() != nil:
		msg.ExtendedTextMessage.ContextInfo = &waE2E.ContextInfo{}
		return msg.ExtendedTextMessage.ContextInfo
	default:
		return nil
	}
}
