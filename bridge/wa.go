package main

import (
	"context"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/polymorfa/hypermeow"
	"github.com/polymorfa/hypermeow/proto/waE2E"
	"github.com/polymorfa/hypermeow/types"
	"github.com/polymorfa/hypermeow/types/events"
	"google.golang.org/protobuf/proto"
)

// Bridge ties the whatsapp client to our store.
type Bridge struct {
	cli       *whatsmeow.Client
	store     *Store
	calls     *Calls
	dataDir   string
	admin     *Admin
	assets    *AssetLooks // 2.10/2.18 assets
	mediaDir  string      // m4a cache
	avatarDir string      // avatar cache, refreshed daily

	presMu   sync.Mutex
	presence map[string]*Presence // online / last seen / typing

	mu         sync.Mutex
	qrCode     string
	pairWanted time.Time
	pairing    bool
}

func (b *Bridge) handle(evt any) {
	switch e := evt.(type) {
	case *events.Message:
		b.onMessage(e, true)
	case *events.Receipt:
		b.onReceipt(e)
	case *events.HistorySync:
		b.onHistory(e)
	case *events.Presence:
		b.onPresence(e)
	case *events.ChatPresence:
		b.onChatPresence(e)
	case *events.DeleteChat:
		b.onDeleteChat(e)
	case *events.Archive:
		chat := b.chatKey(context.Background(), e.JID)
		if err := b.store.SetArchived(chat.String(), e.Action.GetArchived()); err != nil {
			log.Printf("store archive state: %v", err)
		} else {
			b.store.notify()
		}
	case *events.AppStateSyncComplete:
		b.onAppStateSyncComplete(e)
	case *events.PairSuccess:
		log.Printf("paired as %s", e.ID)
	case *events.Connected:
		log.Printf("connected")
	case *events.Disconnected:
		errCounts.add("wa disconnected")
	case *events.KeepAliveTimeout:
		errCounts.add("wa keepalive timeout")
	case *events.StreamReplaced:
		errCounts.add("wa stream replaced")
	case *events.UndecryptableMessage:
		errCounts.add("wa undecryptable")
	case *events.ConnectFailure:
		errCounts.add(fmt.Sprintf("wa connect failure %d", int(e.Reason)))
	case *events.TemporaryBan:
		errCounts.add("wa temporary ban")
	case *events.LoggedOut:
		errCounts.add("wa logged out")
		log.Printf("logged out by the phone (reason %v)", e.Reason)
		b.restartSoon("logged out") // restarts unlinked, shows qr again
	}
}

// chatKey maps LID chats to phone number chats.
func (b *Bridge) chatKey(ctx context.Context, jid types.JID) types.JID {
	jid = jid.ToNonAD()
	if jid.Server == types.HiddenUserServer {
		if pn, err := b.cli.Store.LIDs.GetPNForLID(ctx, jid); err == nil && !pn.IsEmpty() {
			return pn.ToNonAD()
		}
	}
	return jid
}

func skipChat(jid types.JID) bool {
	return jid.Server == types.BroadcastServer || jid.Server == types.NewsletterServer
}

func (b *Bridge) onMessage(e *events.Message, live bool) {
	ctx := context.Background()
	chat := b.chatKey(ctx, e.Info.Chat)
	if skipChat(chat) || e.Message == nil {
		return
	}
	if r := e.Message.GetReactionMessage(); r != nil {
		b.onReaction(ctx, chat, b.chatKey(ctx, e.Info.Sender), e.Info.IsFromMe, r, live)
		return
	}
	kind, text := describe(e.Message)
	if kind == "" {
		return // receipts, reactions etc
	}
	sender := b.chatKey(ctx, e.Info.Sender)
	m := &Message{
		ID:     e.Info.ID,
		Chat:   chat.String(),
		Sender: sender.String(),
		FromMe: e.Info.IsFromMe,
		TS:     unix(e.Info.Timestamp),
		Kind:   kind,
		Text:   text,
		Status: statusDelivered,
		Secs:   mediaSeconds(e.Message),
		Quote:  b.quoteOf(ctx, chat, e.Message),
	}
	if m.FromMe {
		m.Status = statusSent
	}
	var raw []byte
	if kind != "text" {
		raw, _ = proto.Marshal(e.Message)
	}
	added, err := b.store.AddMessage(m, raw, live)
	if err != nil {
		log.Printf("store message: %v", err)
		return
	}
	if added {
		b.ensureChatName(ctx, chat, e.Info.PushName, e.Info.IsFromMe)
		if live {
			b.store.notify()
		}
	}
}

// describe picks what the old app can show.
func describe(msg *waE2E.Message) (kind, text string) {
	switch {
	case msg.GetConversation() != "":
		return "text", msg.GetConversation()
	case msg.GetExtendedTextMessage() != nil:
		return "text", msg.GetExtendedTextMessage().GetText()
	case msg.GetImageMessage() != nil:
		return "image", msg.GetImageMessage().GetCaption()
	case msg.GetVideoMessage() != nil:
		return "video", msg.GetVideoMessage().GetCaption()
	case msg.GetPtvMessage() != nil:
		return "video", ""
	case msg.GetAudioMessage() != nil:
		return "audio", ""
	case msg.GetStickerMessage() != nil:
		return "sticker", ""
	case msg.GetDocumentMessage() != nil:
		return "document", msg.GetDocumentMessage().GetFileName()
	case msg.GetDocumentWithCaptionMessage() != nil:
		return describe(msg.GetDocumentWithCaptionMessage().GetMessage())
	case msg.GetLocationMessage() != nil:
		return "location", msg.GetLocationMessage().GetName()
	case msg.GetContactMessage() != nil:
		return "contact", msg.GetContactMessage().GetDisplayName()
	}
	return "", ""
}

func (b *Bridge) onReceipt(e *events.Receipt) {
	var status int
	switch e.Type {
	case types.ReceiptTypeDelivered:
		status = statusDelivered
	case types.ReceiptTypeRead, types.ReceiptTypePlayed:
		status = statusRead
	default:
		return
	}
	chat := b.chatKey(context.Background(), e.Chat)
	if e.IsFromMe {
		// read on another device, mark read here too
		if status == statusRead {
			b.store.SetUnread(chat.String(), 0)
			b.store.MarkIncomingRead(chat.String())
			b.store.notify()
		}
		return
	}
	if err := b.store.SetStatus(chat.String(), e.MessageIDs, status); err == nil {
		b.store.notify()
	}
}

func (b *Bridge) onHistory(e *events.HistorySync) {
	ctx := context.Background()
	count, archived := 0, 0
	for _, conv := range e.Data.GetConversations() {
		jid, err := types.ParseJID(conv.GetID())
		if err != nil {
			continue
		}
		chat := b.chatKey(ctx, jid)
		if skipChat(chat) {
			continue
		}
		if conv.Archived != nil {
			if err := b.store.SetArchived(chat.String(), conv.GetArchived()); err != nil {
				log.Printf("store history archive state: %v", err)
			} else if conv.GetArchived() {
				archived++
			}
		}
		for _, hm := range conv.GetMessages() {
			evt, err := b.cli.ParseWebMessage(jid, hm.GetMessage())
			if err != nil {
				continue
			}
			b.onMessage(evt, false)
			b.historyReactions(ctx, chat, hm.GetMessage())
			count++
		}
		if name := firstNonEmpty(conv.GetName(), conv.GetDisplayName()); name != "" {
			b.store.SetChatName(chat.String(), name)
		}
		b.store.SetUnread(chat.String(), int(conv.GetUnreadCount()))
	}
	log.Printf("history sync %v: %d conversations, %d messages, %d archived", e.Data.GetSyncType(), len(e.Data.GetConversations()), count, archived)
	b.store.notify()
}

// ensureChatName sets the name the first time.
func (b *Bridge) ensureChatName(ctx context.Context, chat types.JID, pushName string, fromMe bool) {
	if b.store.ChatName(chat.String()) != "" {
		return
	}
	var name string
	if chat.Server == types.GroupServer {
		if info, err := b.cli.GetGroupInfo(ctx, chat); err == nil {
			name = info.Name
		}
	} else {
		name = b.contactName(ctx, chat)
		if name == "" && !fromMe {
			name = pushName
		}
	}
	if name != "" {
		b.store.SetChatName(chat.String(), name)
	}
}

// contactName: address book name first, then push name.
func (b *Bridge) contactName(ctx context.Context, jid types.JID) string {
	c, err := b.cli.Store.Contacts.GetContact(ctx, jid)
	if err == nil && c.Found {
		if n := firstNonEmpty(c.PushName, c.FullName, c.FirstName, c.BusinessName); n != "" {
			return n
		}
	}
	return ""
}

// displayName for titles and group senders.
func (b *Bridge) displayName(ctx context.Context, jid types.JID) string {
	if n := b.contactName(ctx, jid); n != "" {
		return n
	}
	if jid.Server == types.DefaultUserServer {
		return "+" + jid.User
	}
	return jid.User
}

// sendText sends text, as a reply if quoteID is set.
func (b *Bridge) sendText(ctx context.Context, chatStr, text, quoteID string) (*Message, error) {
	chat, err := types.ParseJID(chatStr)
	if err != nil {
		return nil, err
	}
	msg := &waE2E.Message{Conversation: proto.String(text)}
	ci, quote := b.replyTo(chat, quoteID)
	if ci != nil {
		msg = &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{Text: proto.String(text), ContextInfo: ci}}
	}
	resp, err := b.cli.SendMessage(ctx, chat, msg)
	if err != nil {
		return nil, err
	}
	m := &Message{
		ID:     resp.ID,
		Chat:   chat.String(),
		Sender: b.cli.Store.GetJID().ToNonAD().String(),
		FromMe: true,
		TS:     unix(resp.Timestamp),
		Kind:   "text",
		Text:   text,
		Status: statusSent,
		Quote:  quote,
	}
	if _, err := b.store.AddMessage(m, nil, false); err != nil {
		return nil, err
	}
	b.store.notify()
	return m, nil
}

// markRead sends read receipts.
func (b *Bridge) markRead(ctx context.Context, chatStr string) error {
	chat, err := types.ParseJID(chatStr)
	if err != nil {
		return err
	}
	msgs, err := b.store.UnreadIncoming(chatStr, 50)
	if err != nil {
		return err
	}
	bySender := map[string][]types.MessageID{}
	for _, m := range msgs {
		bySender[m.Sender] = append(bySender[m.Sender], m.ID)
	}
	for sender, ids := range bySender {
		s, _ := types.ParseJID(sender)
		if chat.Server != types.GroupServer {
			s = types.EmptyJID
		}
		if err := b.cli.MarkRead(ctx, ids, time.Now(), chat, s); err != nil {
			log.Printf("mark read: %v", err)
		}
	}
	b.store.MarkIncomingRead(chatStr)
	b.store.SetUnread(chatStr, 0)
	b.store.notify()
	return nil
}

// pairLoop keeps showing fresh qr codes while /pair is open.
func (b *Bridge) pairLoop() {
	for {
		if b.cli.Store.ID != nil {
			return
		}
		b.mu.Lock()
		wanted := time.Since(b.pairWanted) < 2*time.Minute
		b.mu.Unlock()
		if !wanted {
			time.Sleep(time.Second)
			continue
		}
		ctx, cancel := context.WithCancel(context.Background())
		ch, err := b.cli.GetQRChannel(ctx)
		if err != nil {
			log.Printf("qr channel: %v", err)
			cancel()
			time.Sleep(5 * time.Second)
			continue
		}
		if err := b.cli.Connect(); err != nil {
			log.Printf("connect: %v", err)
			cancel()
			time.Sleep(5 * time.Second)
			continue
		}
		for item := range ch {
			switch item.Event {
			case whatsmeow.QRChannelEventCode:
				b.setQR(item.Code)
			default:
				log.Printf("pairing: %s", item.Event)
				b.setQR("")
			}
		}
		cancel()
		if b.cli.Store.ID == nil {
			b.cli.Disconnect()
			time.Sleep(3 * time.Second)
		}
	}
}

func (b *Bridge) setQR(code string) {
	b.mu.Lock()
	b.qrCode = code
	b.mu.Unlock()
}

func (b *Bridge) currentQR() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.pairWanted = time.Now()
	return b.qrCode
}

func firstNonEmpty(s ...string) string {
	for _, v := range s {
		if v = strings.TrimSpace(v); v != "" {
			return v
		}
	}
	return ""
}

func parseChat(s string) (types.JID, error) {
	return types.ParseJID(s)
}
