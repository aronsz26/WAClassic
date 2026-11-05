package main

import (
	"context"

	"github.com/polymorfa/hypermeow/proto/waE2E"
	"github.com/polymorfa/hypermeow/types"
	"google.golang.org/protobuf/proto"
)

// contextOf returns the ContextInfo of any message type.
func contextOf(msg *waE2E.Message) *waE2E.ContextInfo {
	switch {
	case msg.GetExtendedTextMessage() != nil:
		return msg.GetExtendedTextMessage().GetContextInfo()
	case msg.GetImageMessage() != nil:
		return msg.GetImageMessage().GetContextInfo()
	case msg.GetVideoMessage() != nil:
		return msg.GetVideoMessage().GetContextInfo()
	case msg.GetPtvMessage() != nil:
		return msg.GetPtvMessage().GetContextInfo()
	case msg.GetAudioMessage() != nil:
		return msg.GetAudioMessage().GetContextInfo()
	case msg.GetStickerMessage() != nil:
		return msg.GetStickerMessage().GetContextInfo()
	case msg.GetDocumentMessage() != nil:
		return msg.GetDocumentMessage().GetContextInfo()
	case msg.GetLocationMessage() != nil:
		return msg.GetLocationMessage().GetContextInfo()
	case msg.GetContactMessage() != nil:
		return msg.GetContactMessage().GetContextInfo()
	}
	return nil
}

// quoteOf returns the quoted message, nil if not a reply.
func (b *Bridge) quoteOf(ctx context.Context, chat types.JID, msg *waE2E.Message) *Quote {
	ci := contextOf(msg)
	if ci.GetStanzaID() == "" || ci.GetQuotedMessage() == nil {
		return nil
	}
	sender := chat // sometimes missing in 1:1 chats
	if p, err := types.ParseJID(ci.GetParticipant()); err == nil && !p.IsEmpty() {
		sender = b.chatKey(ctx, p)
	}
	kind, text := describe(ci.GetQuotedMessage())
	if kind == "" {
		kind = "text"
	}
	own := b.ownJID()
	return &Quote{ID: ci.GetStanzaID(), Sender: sender.String(), FromMe: sender.User == own.User, Kind: kind, Text: text}
}

// replyTo builds the ContextInfo for a reply plus the quote for the app.
func (b *Bridge) replyTo(chat types.JID, id string) (*waE2E.ContextInfo, *Quote) {
	if id == "" {
		return nil, nil
	}
	target, raw, err := b.store.MessageByID(chat.String(), id)
	if err != nil {
		return nil, nil
	}
	quoted := &waE2E.Message{}
	if len(raw) == 0 || proto.Unmarshal(raw, quoted) != nil {
		quoted = &waE2E.Message{Conversation: proto.String(target.Text)}
	}
	sender := target.Sender
	if target.FromMe {
		sender = b.ownJID().String()
	}
	ci := &waE2E.ContextInfo{StanzaID: proto.String(id), Participant: proto.String(sender), QuotedMessage: quoted}
	return ci, &Quote{ID: id, Sender: sender, FromMe: target.FromMe, Kind: target.Kind, Text: target.Text}
}
