# Reconnect & Multi-Device Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable automatic reconnection (phone disconnect + daemon restart) and simultaneous multi-device connections.

**Architecture:** Three-layer change: (1) Signal server rewritten as topic-based pub/sub router, (2) Kite daemon gets persistent pairing code, multi-peer map, and signal auto-reconnect, (3) Web frontend gets full reconnect flow and persistent auth. Plus a new pure-Zig QR code module.

**Tech Stack:** Go (signal server), Zig 0.15.2 (kite daemon), Svelte 5 + TypeScript (web frontend)

**Spec:** `docs/superpowers/specs/2026-04-06-reconnect-multidevice-design.md`

---

## File Map

| Action | File | Purpose |
|--------|------|---------|
| Rewrite | `signal/room.go` | Topic model replacing Room model |
| Rewrite | `signal/room_test.go` | Tests for Topic model |
| Rewrite | `signal/main.go` | New WebSocket handler for topic protocol |
| Rewrite | `signal/main_test.go` | Integration tests for new protocol |
| Modify | `src/main.zig` | Config persistence, multi-peer, protocol adaptation, default URL |
| Modify | `src/signal_client.zig` | Auto-reconnect with exponential backoff |
| Modify | `src/auth.zig` | Reusable setup secret, remove one-time guard |
| Create | `src/qr.zig` | QR code encoder + terminal renderer |
| Modify | `web/src/lib/signal.ts` | New signal protocol (join with role, member events, relay) |
| Modify | `web/src/lib/webrtc.ts` | Reconnect with full WebRTC rebuild |
| Modify | `web/src/App.svelte` | Don't clear localStorage, waiting states |

---

### Task 1: Signal Server — Topic Model

Rewrite `signal/room.go` to replace the 1:1 Room model with a multi-member Topic model.

**Files:**
- Rewrite: `signal/room.go`
- Rewrite: `signal/room_test.go`

- [ ] **Step 1: Write tests for Topic model**

Replace the entire contents of `signal/room_test.go`:

```go
package signal

import (
	"errors"
	"strings"
	"sync"
	"testing"
	"time"
)

type mockSender struct {
	mu       sync.Mutex
	messages [][]byte
	sendErr  error
}

func newMockSender() *mockSender {
	return &mockSender{}
}

func (m *mockSender) Send(data []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.sendErr != nil {
		return m.sendErr
	}
	cp := make([]byte, len(data))
	copy(cp, data)
	m.messages = append(m.messages, cp)
	return nil
}

func (m *mockSender) Messages() [][]byte {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([][]byte, len(m.messages))
	copy(out, m.messages)
	return out
}

func (m *mockSender) hasMessage(substr string) bool {
	for _, msg := range m.Messages() {
		if strings.Contains(string(msg), substr) {
			return true
		}
	}
	return false
}

func TestJoinCreatesTopic(t *testing.T) {
	tm := NewTopicManager()
	daemon := newMockSender()

	id, members, err := tm.Join("ABCDEF", "daemon", daemon)
	if err != nil {
		t.Fatalf("Join: %v", err)
	}
	if id == "" {
		t.Fatal("expected non-empty member ID")
	}
	if len(members) != 0 {
		t.Fatalf("expected 0 existing members, got %d", len(members))
	}
}

func TestJoinNotifiesExistingMembers(t *testing.T) {
	tm := NewTopicManager()
	daemon := newMockSender()
	browser := newMockSender()

	tm.Join("ABCDEF", "daemon", daemon)
	id2, members, _ := tm.Join("ABCDEF", "browser", browser)

	// Should get 1 existing member (the daemon)
	if len(members) != 1 {
		t.Fatalf("expected 1 existing member, got %d", len(members))
	}
	if members[0].Role != "daemon" {
		t.Fatalf("expected daemon role, got %s", members[0].Role)
	}

	// Daemon should receive member_joined
	if !daemon.hasMessage("member_joined") {
		t.Fatal("daemon should receive member_joined")
	}
	if !daemon.hasMessage(id2) {
		t.Fatal("daemon should receive new member's ID")
	}
}

func TestRelayToSpecificMember(t *testing.T) {
	tm := NewTopicManager()
	daemon := newMockSender()
	browser := newMockSender()

	daemonID, _, _ := tm.Join("ABCDEF", "daemon", daemon)
	browserID, _, _ := tm.Join("ABCDEF", "browser", browser)

	// Browser relays to daemon
	err := tm.Relay("ABCDEF", browserID, daemonID, []byte(`{"type":"sdp_offer"}`))
	if err != nil {
		t.Fatalf("Relay: %v", err)
	}
	if !daemon.hasMessage("sdp_offer") {
		t.Fatal("daemon should receive relayed message")
	}
}

func TestBroadcast(t *testing.T) {
	tm := NewTopicManager()
	d := newMockSender()
	b1 := newMockSender()
	b2 := newMockSender()

	dID, _, _ := tm.Join("ABCDEF", "daemon", d)
	tm.Join("ABCDEF", "browser", b1)
	tm.Join("ABCDEF", "browser", b2)

	err := tm.Broadcast("ABCDEF", dID, []byte(`{"type":"test"}`))
	if err != nil {
		t.Fatalf("Broadcast: %v", err)
	}
	// Both browsers should get it, daemon should not
	if !b1.hasMessage("test") {
		t.Fatal("b1 should receive broadcast")
	}
	if !b2.hasMessage("test") {
		t.Fatal("b2 should receive broadcast")
	}
	// daemon should only have member_joined notifications, not the broadcast
	for _, msg := range d.Messages() {
		if strings.Contains(string(msg), `"type":"test"`) {
			t.Fatal("daemon should not receive its own broadcast")
		}
	}
}

func TestDisconnectNotifiesOthers(t *testing.T) {
	tm := NewTopicManager()
	daemon := newMockSender()
	browser := newMockSender()

	daemonID, _, _ := tm.Join("ABCDEF", "daemon", daemon)
	tm.Join("ABCDEF", "browser", browser)

	tm.Disconnect("ABCDEF", daemonID)

	if !browser.hasMessage("member_left") {
		t.Fatal("browser should receive member_left")
	}
	if !browser.hasMessage(daemonID) {
		t.Fatal("browser should receive daemon's ID in member_left")
	}
}

func TestTopicTTLCleanup(t *testing.T) {
	tm := NewTopicManager()
	tm.topicTTL = 50 * time.Millisecond

	daemon := newMockSender()
	daemonID, _, _ := tm.Join("ABCDEF", "daemon", daemon)
	tm.Disconnect("ABCDEF", daemonID) // last member leaves

	time.Sleep(100 * time.Millisecond)
	tm.CleanupStale()

	// Topic should be gone — new join should get empty members
	b := newMockSender()
	_, members, err := tm.Join("ABCDEF", "browser", b)
	if err != nil {
		t.Fatalf("Join after cleanup: %v", err)
	}
	if len(members) != 0 {
		t.Fatalf("expected fresh topic with 0 members, got %d", len(members))
	}
}

func TestTopicSurvivesWithinTTL(t *testing.T) {
	tm := NewTopicManager()
	tm.topicTTL = 5 * time.Second

	daemon := newMockSender()
	daemonID, _, _ := tm.Join("ABCDEF", "daemon", daemon)
	tm.Disconnect("ABCDEF", daemonID)

	// Rejoin within TTL
	d2 := newMockSender()
	_, _, err := tm.Join("ABCDEF", "daemon", d2)
	if err != nil {
		t.Fatalf("Rejoin: %v", err)
	}
}

func TestRelayToNonexistentMember(t *testing.T) {
	tm := NewTopicManager()
	daemon := newMockSender()
	dID, _, _ := tm.Join("ABCDEF", "daemon", daemon)

	err := tm.Relay("ABCDEF", dID, "nonexistent", []byte(`hello`))
	if !errors.Is(err, ErrMemberNotFound) {
		t.Fatalf("expected ErrMemberNotFound, got %v", err)
	}
}

func TestRelayToNonexistentTopic(t *testing.T) {
	tm := NewTopicManager()
	err := tm.Relay("NOPE", "a", "b", []byte(`hello`))
	if !errors.Is(err, ErrTopicNotFound) {
		t.Fatalf("expected ErrTopicNotFound, got %v", err)
	}
}

func TestRateLimitOnJoin(t *testing.T) {
	tm := NewTopicManager()
	tm.maxJoinAttempts = 3

	ip := "10.0.0.1"
	for i := 0; i < 3; i++ {
		tm.JoinWithIP("NOPE00", "browser", newMockSender(), ip)
	}

	_, _, err := tm.JoinWithIP("ABCDEF", "browser", newMockSender(), ip)
	if !errors.Is(err, ErrRateLimited) {
		t.Fatalf("expected ErrRateLimited, got %v", err)
	}
}

func TestConcurrentJoins(t *testing.T) {
	tm := NewTopicManager()
	var wg sync.WaitGroup

	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			tm.Join("ROOM01", "browser", newMockSender())
		}(i)
	}
	wg.Wait()
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/aneryu/kite/signal && go test ./... -v
```

Expected: compilation errors (TopicManager, etc. don't exist yet).

- [ ] **Step 3: Implement Topic model**

Replace the entire contents of `signal/room.go`:

```go
package signal

import (
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"crypto/rand"
	"encoding/hex"
)

var (
	ErrTopicNotFound  = errors.New("topic not found")
	ErrMemberNotFound = errors.New("member not found")
	ErrRateLimited    = errors.New("rate limited")
)

// Sender is the interface for sending data to a WebSocket connection.
type Sender interface {
	Send(data []byte) error
}

// MemberInfo is the public view of a member (returned in joined response).
type MemberInfo struct {
	ID   string `json:"id"`
	Role string `json:"role"`
}

// Member represents a connected client in a topic.
type Member struct {
	ID   string
	Role string
	Conn Sender
}

// Topic represents a signaling channel identified by a pairing code.
type Topic struct {
	Code       string
	Members    map[string]*Member
	LastActive time.Time
	EmptySince *time.Time // set when last member leaves, cleared on join
}

type rateLimitEntry struct {
	count    int
	windowAt time.Time
}

// TopicManager manages signaling topics with thread-safe access.
type TopicManager struct {
	mu     sync.Mutex
	topics map[string]*Topic

	topicTTL        time.Duration
	maxJoinAttempts int
	joinAttempts    map[string]*rateLimitEntry
}

// NewTopicManager creates a new TopicManager with default settings.
func NewTopicManager() *TopicManager {
	return &TopicManager{
		topics:          make(map[string]*Topic),
		topicTTL:        5 * time.Minute,
		maxJoinAttempts: 30,
		joinAttempts:    make(map[string]*rateLimitEntry),
	}
}

func generateMemberID() string {
	b := make([]byte, 8)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// Join adds a member to a topic. Creates the topic if it doesn't exist.
// Returns the new member's ID and the list of existing members.
func (tm *TopicManager) Join(code string, role string, conn Sender) (string, []MemberInfo, error) {
	return tm.JoinWithIP(code, role, conn, "")
}

// JoinWithIP is like Join but also applies rate limiting by IP.
func (tm *TopicManager) JoinWithIP(code string, role string, conn Sender, ip string) (string, []MemberInfo, error) {
	tm.mu.Lock()
	defer tm.mu.Unlock()

	if ip != "" {
		if err := tm.checkRateLimit(ip); err != nil {
			return "", nil, err
		}
	}

	topic, exists := tm.topics[code]
	if !exists {
		topic = &Topic{
			Code:    code,
			Members: make(map[string]*Member),
		}
		tm.topics[code] = topic
	}

	// Clear empty timer on join
	topic.EmptySince = nil
	topic.LastActive = time.Now()

	// Clear rate limit on successful join
	if ip != "" {
		delete(tm.joinAttempts, ip)
	}

	// Collect existing members before adding new one
	existing := make([]MemberInfo, 0, len(topic.Members))
	for _, m := range topic.Members {
		existing = append(existing, MemberInfo{ID: m.ID, Role: m.Role})
	}

	// Create new member
	id := generateMemberID()
	topic.Members[id] = &Member{ID: id, Role: role, Conn: conn}

	// Notify existing members
	notification, _ := json.Marshal(map[string]string{
		"type":      "member_joined",
		"member_id": id,
		"role":      role,
	})
	for _, m := range topic.Members {
		if m.ID != id {
			m.Conn.Send(notification)
		}
	}

	return id, existing, nil
}

// Disconnect removes a member from a topic and notifies others.
func (tm *TopicManager) Disconnect(code string, memberID string) {
	tm.mu.Lock()
	defer tm.mu.Unlock()

	topic, exists := tm.topics[code]
	if !exists {
		return
	}

	delete(topic.Members, memberID)

	// Notify remaining members
	notification, _ := json.Marshal(map[string]string{
		"type":      "member_left",
		"member_id": memberID,
	})
	for _, m := range topic.Members {
		m.Conn.Send(notification)
	}

	// Start TTL timer if topic is now empty
	if len(topic.Members) == 0 {
		now := time.Now()
		topic.EmptySince = &now
	}
	topic.LastActive = time.Now()
}

// Relay sends data from one member to a specific other member.
func (tm *TopicManager) Relay(code string, fromID string, toID string, data []byte) error {
	tm.mu.Lock()
	defer tm.mu.Unlock()

	topic, exists := tm.topics[code]
	if !exists {
		return ErrTopicNotFound
	}

	target, exists := topic.Members[toID]
	if !exists {
		return ErrMemberNotFound
	}

	// Wrap in relay envelope
	envelope, _ := json.Marshal(map[string]interface{}{
		"type":    "relay",
		"from":    fromID,
		"payload": json.RawMessage(data),
	})
	topic.LastActive = time.Now()
	return target.Conn.Send(envelope)
}

// Broadcast sends data to all members in the topic except the sender.
func (tm *TopicManager) Broadcast(code string, fromID string, data []byte) error {
	tm.mu.Lock()
	defer tm.mu.Unlock()

	topic, exists := tm.topics[code]
	if !exists {
		return ErrTopicNotFound
	}

	envelope, _ := json.Marshal(map[string]interface{}{
		"type":    "relay",
		"from":    fromID,
		"payload": json.RawMessage(data),
	})

	var lastErr error
	for _, m := range topic.Members {
		if m.ID != fromID {
			if err := m.Conn.Send(envelope); err != nil {
				lastErr = err
			}
		}
	}
	topic.LastActive = time.Now()
	return lastErr
}

// GetMemberInfo returns info about a specific member.
func (tm *TopicManager) GetMemberInfo(code string, memberID string) (*MemberInfo, error) {
	tm.mu.Lock()
	defer tm.mu.Unlock()

	topic, exists := tm.topics[code]
	if !exists {
		return nil, ErrTopicNotFound
	}
	m, exists := topic.Members[memberID]
	if !exists {
		return nil, ErrMemberNotFound
	}
	return &MemberInfo{ID: m.ID, Role: m.Role}, nil
}

// CleanupStale removes empty topics that have exceeded their TTL.
func (tm *TopicManager) CleanupStale() {
	tm.mu.Lock()
	defer tm.mu.Unlock()

	now := time.Now()
	for code, topic := range tm.topics {
		if topic.EmptySince != nil && now.Sub(*topic.EmptySince) > tm.topicTTL {
			delete(tm.topics, code)
		}
	}
}

// TopicCount returns the number of active topics (for monitoring).
func (tm *TopicManager) TopicCount() int {
	tm.mu.Lock()
	defer tm.mu.Unlock()
	return len(tm.topics)
}

func (tm *TopicManager) checkRateLimit(ip string) error {
	entry, exists := tm.joinAttempts[ip]
	if !exists {
		return nil
	}
	if time.Since(entry.windowAt) > time.Minute {
		delete(tm.joinAttempts, ip)
		return nil
	}
	if entry.count >= tm.maxJoinAttempts {
		return ErrRateLimited
	}
	return nil
}

func (tm *TopicManager) recordAttempt(ip string) {
	entry, exists := tm.joinAttempts[ip]
	if !exists || time.Since(entry.windowAt) > time.Minute {
		tm.joinAttempts[ip] = &rateLimitEntry{count: 1, windowAt: time.Now()}
		return
	}
	entry.count++
}

// String returns a debug representation of a topic.
func (t *Topic) String() string {
	return fmt.Sprintf("Topic{code=%s, members=%d}", t.Code, len(t.Members))
}
```

- [ ] **Step 4: Run tests**

```bash
cd /Users/aneryu/kite/signal && go test ./... -run "^Test(Join|Relay|Broadcast|Disconnect|TopicTTL|TopicSurvives|RateLimit|Concurrent)" -v
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/aneryu/kite && git add signal/room.go signal/room_test.go
git commit -m "refactor(signal): replace Room model with Topic-based pub/sub"
```

---

### Task 2: Signal Server — WebSocket Handler

Rewrite `signal/main.go` to handle the new topic-based protocol.

**Files:**
- Rewrite: `signal/main.go`
- Rewrite: `signal/main_test.go`

- [ ] **Step 1: Write integration tests**

Replace the entire contents of `signal/main_test.go`:

```go
package signal

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func wsURL(s *httptest.Server) string {
	return "ws" + strings.TrimPrefix(s.URL, "http") + "/ws"
}

func dial(t *testing.T, url string) *websocket.Conn {
	t.Helper()
	ws, _, err := websocket.DefaultDialer.Dial(url, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	return ws
}

func sendJSON(t *testing.T, ws *websocket.Conn, v interface{}) {
	t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := ws.WriteMessage(websocket.TextMessage, data); err != nil {
		t.Fatalf("write: %v", err)
	}
}

func readJSON(t *testing.T, ws *websocket.Conn) map[string]interface{} {
	t.Helper()
	ws.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, data, err := ws.ReadMessage()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var msg map[string]interface{}
	if err := json.Unmarshal(data, &msg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	return msg
}

func TestWSJoinAndMemberNotification(t *testing.T) {
	tm := NewTopicManager()
	handler := NewHandler(tm, "")
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// Daemon joins
	daemon := dial(t, wsURL(srv))
	defer daemon.Close()
	sendJSON(t, daemon, map[string]string{
		"type": "join", "pairing_code": "TEST01", "role": "daemon",
	})
	joinMsg := readJSON(t, daemon)
	if joinMsg["type"] != "joined" {
		t.Fatalf("expected joined, got %v", joinMsg["type"])
	}
	daemonID := joinMsg["member_id"].(string)
	if daemonID == "" {
		t.Fatal("expected non-empty member_id")
	}

	// Browser joins
	browser := dial(t, wsURL(srv))
	defer browser.Close()
	sendJSON(t, browser, map[string]string{
		"type": "join", "pairing_code": "TEST01", "role": "browser",
	})
	browserJoin := readJSON(t, browser)
	if browserJoin["type"] != "joined" {
		t.Fatalf("expected joined, got %v", browserJoin["type"])
	}
	members := browserJoin["members"].([]interface{})
	if len(members) != 1 {
		t.Fatalf("expected 1 existing member, got %d", len(members))
	}

	// Daemon should receive member_joined
	memberJoined := readJSON(t, daemon)
	if memberJoined["type"] != "member_joined" {
		t.Fatalf("expected member_joined, got %v", memberJoined["type"])
	}
}

func TestWSRelayBetweenMembers(t *testing.T) {
	tm := NewTopicManager()
	handler := NewHandler(tm, "")
	srv := httptest.NewServer(handler)
	defer srv.Close()

	daemon := dial(t, wsURL(srv))
	defer daemon.Close()
	sendJSON(t, daemon, map[string]string{
		"type": "join", "pairing_code": "RELAY1", "role": "daemon",
	})
	daemonJoin := readJSON(t, daemon)
	daemonID := daemonJoin["member_id"].(string)

	browser := dial(t, wsURL(srv))
	defer browser.Close()
	sendJSON(t, browser, map[string]string{
		"type": "join", "pairing_code": "RELAY1", "role": "browser",
	})
	browserJoin := readJSON(t, browser)
	browserID := browserJoin["member_id"].(string)
	readJSON(t, daemon) // member_joined

	// Browser sends relay to daemon
	sendJSON(t, browser, map[string]interface{}{
		"type": "relay", "to": daemonID,
		"payload": map[string]string{"type": "sdp_offer", "sdp": "test"},
	})
	relayed := readJSON(t, daemon)
	if relayed["type"] != "relay" {
		t.Fatalf("expected relay, got %v", relayed["type"])
	}
	if relayed["from"] != browserID {
		t.Fatalf("expected from=%s, got %v", browserID, relayed["from"])
	}
}

func TestWSBroadcast(t *testing.T) {
	tm := NewTopicManager()
	handler := NewHandler(tm, "")
	srv := httptest.NewServer(handler)
	defer srv.Close()

	daemon := dial(t, wsURL(srv))
	defer daemon.Close()
	sendJSON(t, daemon, map[string]string{
		"type": "join", "pairing_code": "BCAST1", "role": "daemon",
	})
	readJSON(t, daemon) // joined

	b1 := dial(t, wsURL(srv))
	defer b1.Close()
	sendJSON(t, b1, map[string]string{
		"type": "join", "pairing_code": "BCAST1", "role": "browser",
	})
	readJSON(t, b1)     // joined
	readJSON(t, daemon) // member_joined

	b2 := dial(t, wsURL(srv))
	defer b2.Close()
	sendJSON(t, b2, map[string]string{
		"type": "join", "pairing_code": "BCAST1", "role": "browser",
	})
	readJSON(t, b2)     // joined
	readJSON(t, daemon) // member_joined
	readJSON(t, b1)     // member_joined (b2)

	// Daemon broadcasts
	sendJSON(t, daemon, map[string]interface{}{
		"type":    "broadcast",
		"payload": map[string]string{"type": "test_data"},
	})

	r1 := readJSON(t, b1)
	if r1["type"] != "relay" {
		t.Fatalf("b1: expected relay, got %v", r1["type"])
	}
	r2 := readJSON(t, b2)
	if r2["type"] != "relay" {
		t.Fatalf("b2: expected relay, got %v", r2["type"])
	}
}

func TestWSDisconnectNotification(t *testing.T) {
	tm := NewTopicManager()
	handler := NewHandler(tm, "")
	srv := httptest.NewServer(handler)
	defer srv.Close()

	daemon := dial(t, wsURL(srv))
	sendJSON(t, daemon, map[string]string{
		"type": "join", "pairing_code": "DISC01", "role": "daemon",
	})
	readJSON(t, daemon) // joined

	browser := dial(t, wsURL(srv))
	defer browser.Close()
	sendJSON(t, browser, map[string]string{
		"type": "join", "pairing_code": "DISC01", "role": "browser",
	})
	readJSON(t, browser) // joined
	readJSON(t, daemon)  // member_joined

	daemon.Close()

	msg := readJSON(t, browser)
	if msg["type"] != "member_left" {
		t.Fatalf("expected member_left, got %v", msg["type"])
	}
}
```

- [ ] **Step 2: Implement new WebSocket handler**

Replace the entire contents of `signal/main.go`:

```go
package signal

import (
	"embed"
	"encoding/json"
	"io/fs"
	"log"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

//go:embed static
var staticFiles embed.FS

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

type wsConn struct {
	conn *websocket.Conn
	mu   sync.Mutex
}

func (w *wsConn) Send(data []byte) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.conn.WriteMessage(websocket.TextMessage, data)
}

func (w *wsConn) SendPing() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.conn.WriteMessage(websocket.PingMessage, nil)
}

type signalMsg struct {
	Type        string          `json:"type"`
	PairingCode string          `json:"pairing_code,omitempty"`
	Role        string          `json:"role,omitempty"`
	To          string          `json:"to,omitempty"`
	Payload     json.RawMessage `json:"payload,omitempty"`
}

type Handler struct {
	tm       *TopicManager
	staticFS http.Handler
	mux      *http.ServeMux
}

func NewHandler(tm *TopicManager, staticDir string) http.Handler {
	h := &Handler{
		tm:  tm,
		mux: http.NewServeMux(),
	}

	if staticDir != "" {
		h.staticFS = http.FileServer(http.Dir(staticDir))
	} else {
		sub, err := fs.Sub(staticFiles, "static")
		if err != nil {
			log.Fatalf("failed to create sub filesystem: %v", err)
		}
		h.staticFS = http.FileServer(http.FS(sub))
	}

	h.mux.HandleFunc("/ws", h.handleWebSocket)
	h.mux.Handle("/", h.staticFS)

	return h
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h.mux.ServeHTTP(w, r)
}

func (h *Handler) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("websocket upgrade failed: %v", err)
		return
	}
	defer ws.Close()

	conn := &wsConn{conn: ws}
	ip := clientIP(r)

	// Read first message — must be a join
	_, data, err := ws.ReadMessage()
	if err != nil {
		return
	}

	var msg signalMsg
	if err := json.Unmarshal(data, &msg); err != nil {
		conn.Send([]byte(`{"type":"error","error":"invalid message"}`))
		return
	}

	if msg.Type != "join" {
		conn.Send([]byte(`{"type":"error","error":"first message must be join"}`))
		return
	}

	if msg.PairingCode == "" || msg.Role == "" {
		conn.Send([]byte(`{"type":"error","error":"pairing_code and role required"}`))
		return
	}

	memberID, members, err := h.tm.JoinWithIP(msg.PairingCode, msg.Role, conn, ip)
	if err != nil {
		errMsg, _ := json.Marshal(map[string]string{"type": "error", "error": err.Error()})
		conn.Send(errMsg)
		return
	}
	defer h.tm.Disconnect(msg.PairingCode, memberID)

	// Send joined confirmation with member list
	joinResp, _ := json.Marshal(map[string]interface{}{
		"type":      "joined",
		"member_id": memberID,
		"members":   members,
	})
	conn.Send(joinResp)

	log.Printf("[signal] %s joined topic %s as %s (id=%s)", ip, msg.PairingCode, msg.Role, memberID)

	// Start ping ticker
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	go func() {
		for range ticker.C {
			if err := conn.SendPing(); err != nil {
				return
			}
		}
	}()

	// Message loop
	for {
		_, data, err := ws.ReadMessage()
		if err != nil {
			log.Printf("[signal] %s read error: %v", memberID, err)
			return
		}

		var inMsg signalMsg
		if err := json.Unmarshal(data, &inMsg); err != nil {
			continue
		}

		switch inMsg.Type {
		case "relay":
			if inMsg.To == "" || inMsg.Payload == nil {
				continue
			}
			if err := h.tm.Relay(msg.PairingCode, memberID, inMsg.To, inMsg.Payload); err != nil {
				log.Printf("[signal] relay error: %v", err)
			}
		case "broadcast":
			if inMsg.Payload == nil {
				continue
			}
			if err := h.tm.Broadcast(msg.PairingCode, memberID, inMsg.Payload); err != nil {
				log.Printf("[signal] broadcast error: %v", err)
			}
		}
	}
}

func truncate(data []byte, max int) string {
	if len(data) <= max {
		return string(data)
	}
	return string(data[:max]) + "..."
}

func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		return xff
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
```

- [ ] **Step 3: Run all signal tests**

```bash
cd /Users/aneryu/kite/signal && go test ./... -v
```

Expected: all tests pass (both unit and integration).

- [ ] **Step 4: Commit**

```bash
cd /Users/aneryu/kite && git add signal/main.go signal/main_test.go
git commit -m "refactor(signal): implement topic-based WebSocket handler"
```

---

### Task 3: Kite — Config Persistence & Default URL

Persist pairing code and setup secret in config file. Change default signal URL.

**Files:**
- Modify: `src/main.zig:18-98` (Config, FileConfig, readConfigFile, runStart, runSetup)
- Modify: `src/auth.zig:1-99` (remove one-time guard, add setup secret support)

- [ ] **Step 1: Update FileConfig to include pairing_code and setup_secret**

In `src/main.zig`, replace the `FileConfig` struct and `readConfigFile` function (lines 78-98):

```zig
const FileConfig = struct {
    signal_url: []const u8 = "wss://relay.fun.dev",
    pairing_code: []const u8 = "",
    setup_secret: []const u8 = "",
};

fn readConfigFile(allocator: std.mem.Allocator) ?FileConfig {
    const home = std.posix.getenv("HOME") orelse return null;
    const config_path = std.fmt.allocPrint(allocator, "{s}/.config/kite/config.json", .{home}) catch return null;
    defer allocator.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch return null;
    defer file.close();

    const contents = file.readToEndAlloc(allocator, 4096) catch return null;
    defer allocator.free(contents);

    const parsed = std.json.parseFromSlice(FileConfig, allocator, contents, .{ .ignore_unknown_fields = true }) catch return null;
    const url = allocator.dupe(u8, parsed.value.signal_url) catch return null;
    const code = allocator.dupe(u8, parsed.value.pairing_code) catch return null;
    const secret = allocator.dupe(u8, parsed.value.setup_secret) catch return null;
    parsed.deinit();
    return FileConfig{ .signal_url = url, .pairing_code = code, .setup_secret = secret };
}

fn writeConfigFile(allocator: std.mem.Allocator, config: FileConfig) void {
    const home = std.posix.getenv("HOME") orelse return;
    const config_dir = std.fmt.allocPrint(allocator, "{s}/.config/kite", .{home}) catch return;
    defer allocator.free(config_dir);
    const parent_dir = std.fmt.allocPrint(allocator, "{s}/.config", .{home}) catch return;
    defer allocator.free(parent_dir);
    std.fs.makeDirAbsolute(parent_dir) catch {};
    std.fs.makeDirAbsolute(config_dir) catch {};

    const config_path = std.fmt.allocPrint(allocator, "{s}/config.json", .{config_dir}) catch return;
    defer allocator.free(config_path);

    const escaped_url = protocol.jsonEscapeAllocPublic(allocator, config.signal_url) catch return;
    defer allocator.free(escaped_url);
    const config_json = std.fmt.allocPrint(allocator, "{{\"signal_url\":\"{s}\",\"pairing_code\":\"{s}\",\"setup_secret\":\"{s}\"}}\n", .{ escaped_url, config.pairing_code, config.setup_secret }) catch return;
    defer allocator.free(config_json);

    const file = std.fs.createFileAbsolute(config_path, .{}) catch return;
    defer file.close();
    file.writeAll(config_json) catch {};
}
```

- [ ] **Step 2: Update Config default signal_url**

In `src/main.zig`, change `Config` struct (line 22):

Old: `signal_url: []const u8 = "ws://localhost:8080",`
New: `signal_url: []const u8 = "wss://relay.fun.dev",`

- [ ] **Step 3: Update runStart to use persistent pairing code and setup secret**

In `src/main.zig`, replace the config reading and pairing code generation section in `runStart` (lines 110-168). The key changes:

1. Read `pairing_code` and `setup_secret` from FileConfig
2. If empty, generate new ones and write config
3. Use persistent setup_secret instead of one-time setup_token
4. Pass setup_secret to auth

Replace lines 110-168 of `runStart`:

```zig
fn runStart(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var config = Config{};

    // Read config file defaults
    var file_config = readConfigFile(allocator) orelse FileConfig{};
    config.signal_url = file_config.signal_url;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--no-auth")) {
            config.no_auth = true;
        } else if (std.mem.eql(u8, args[i], "--signal-url") and i + 1 < args.len) {
            config.signal_url = args[i + 1];
            i += 1;
        }
    }

    if (daemon.isRunning()) {
        const stderr_file = std.fs.File.stderr();
        _ = stderr_file.write("kite daemon is already running.\n") catch {};
        return;
    }

    try daemon.writePidFile();
    defer daemon.removePidFile();

    const stdout_file = std.fs.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    // Generate or load persistent pairing code and setup secret
    var pairing_code: [6]u8 = undefined;
    var setup_secret_hex: [64]u8 = undefined;

    if (file_config.pairing_code.len == 6 and file_config.setup_secret.len == 64) {
        @memcpy(&pairing_code, file_config.pairing_code[0..6]);
        @memcpy(&setup_secret_hex, file_config.setup_secret[0..64]);
    } else {
        pairing_code = auth_mod.generatePairingCode();
        var secret_bytes: [32]u8 = undefined;
        std.crypto.random.bytes(&secret_bytes);
        setup_secret_hex = std.fmt.bytesToHex(secret_bytes, .lower);
        // Save to config
        file_config.pairing_code = &pairing_code;
        file_config.setup_secret = &setup_secret_hex;
        file_config.signal_url = config.signal_url;
        writeConfigFile(allocator, file_config);
    }

    var auth = Auth.init();
    auth.disabled = config.no_auth;
    auth.setSetupSecret(&setup_secret_hex);

    const signal_host, const signal_port = parseSignalUrl(config.signal_url);

    try stdout.print("\n  kite daemon started\n", .{});
    try stdout.print("  ====================\n\n", .{});
    try stdout.print("  Signal server: {s}\n", .{config.signal_url});
    try stdout.print("  Pairing code:  {s}\n\n", .{pairing_code});

    if (config.no_auth) {
        try stdout.print("  Auth disabled -- connect directly, no token required.\n\n", .{});
    } else {
        const http_url = if (std.mem.startsWith(u8, config.signal_url, "wss://"))
            try std.fmt.allocPrint(allocator, "https://{s}", .{config.signal_url[6..]})
        else if (std.mem.startsWith(u8, config.signal_url, "ws://"))
            try std.fmt.allocPrint(allocator, "http://{s}", .{config.signal_url[5..]})
        else
            try allocator.dupe(u8, config.signal_url);
        defer allocator.free(http_url);

        try stdout.print("  Scan QR code or open this URL on your phone:\n", .{});
        try stdout.print("  {s}/#/pair/{s}:{s}\n\n", .{ http_url, pairing_code, setup_secret_hex });
    }
    try stdout.print("  Use 'kite run' to create a session.\n\n", .{});
    try stdout.flush();
```

The rest of `runStart` (from `// Create message queues` onward) continues unchanged, EXCEPT the signal client registration needs to change — see Task 5.

- [ ] **Step 4: Update auth.zig — remove one-time guard, add setSetupSecret**

In `src/auth.zig`, make these changes:

Replace `validateSetupToken` (lines 36-50) to remove one-time guard:

```zig
pub fn validateSetupSecret(self: *Auth, secret_hex: []const u8) ?[128]u8 {
    if (self.setup_secret_hex.len == 0) return null;
    if (!std.mem.eql(u8, secret_hex, &self.setup_secret_hex)) return null;

    // Generate a new session token
    var session_bytes: [64]u8 = undefined;
    crypto.random.bytes(&session_bytes);
    self.session_token = session_bytes;
    self.session_token_created = std.time.timestamp();
    return std.fmt.bytesToHex(session_bytes, .lower);
}

pub fn setSetupSecret(self: *Auth, hex: []const u8) void {
    if (hex.len == 64) {
        @memcpy(&self.setup_secret_hex, hex[0..64]);
    }
}
```

Add `setup_secret_hex` field to the Auth struct and remove `setup_token_used`:

```zig
pub const Auth = struct {
    secret: [32]u8,
    setup_secret_hex: [64]u8 = .{0} ** 64,
    session_token: ?[64]u8 = null,
    session_token_created: i64 = 0,
    disabled: bool = false,
```

Remove `setup_token_used`, `setup_token_created`, and `getSetupTokenHex`. Remove the `renderQrCode` function (QR rendering moves to `qr.zig` + `runStatus`).

Update the `handleAuthMessage` function in `main.zig` to call `validateSetupSecret` instead of `validateSetupToken`.

- [ ] **Step 5: Update runSetup default URL and config write**

In `src/main.zig`, change `runSetup` (line 1157):

Old: `var signal_url: []const u8 = "ws://localhost:8080";`
New: `var signal_url: []const u8 = "wss://relay.fun.dev";`

Also add `--reset` flag support to regenerate pairing code and setup secret.

- [ ] **Step 6: Verify build**

```bash
cd /Users/aneryu/kite && zig build
```

Expected: builds successfully.

- [ ] **Step 7: Commit**

```bash
cd /Users/aneryu/kite && git add src/main.zig src/auth.zig
git commit -m "feat: persistent pairing code/setup secret, default to wss://relay.fun.dev"
```

---

### Task 4: Kite — Signal Client Auto-Reconnect

Add exponential backoff reconnection to `SignalClient`.

**Files:**
- Modify: `src/signal_client.zig`

- [ ] **Step 1: Add reconnect logic to SignalClient**

The current `readLoop` (line 125-196 of signal_client.zig) exits on error with no retry. Add reconnection with exponential backoff.

Key changes to `signal_client.zig`:

1. Add `reconnect_delay_ms: u64 = 2000` and `max_reconnect_delay_ms: u64 = 30000` fields
2. Add `host`, `port`, `path` fields (store connection params for reconnect)
3. Add `pairing_code` and `role` fields for re-registration
4. Change `readLoop` to loop with reconnect on disconnect:

```zig
pub fn readLoop(self: *SignalClient) void {
    while (true) {
        self.readLoopInner() catch {};
        self.connected = false;

        // Exponential backoff reconnect
        logStderr("[signal] Disconnected, reconnecting in {d}ms...", .{self.reconnect_delay_ms});
        std.Thread.sleep(self.reconnect_delay_ms * std.time.ns_per_ms);

        // Try to reconnect
        self.reconnect() catch {
            self.reconnect_delay_ms = @min(self.reconnect_delay_ms * 2, self.max_reconnect_delay_ms);
            continue;
        };

        // Re-join the topic
        self.joinTopic() catch {
            self.reconnect_delay_ms = @min(self.reconnect_delay_ms * 2, self.max_reconnect_delay_ms);
            continue;
        };

        // Reset backoff on successful connection
        self.reconnect_delay_ms = 2000;
        logStderr("[signal] Reconnected successfully", .{});
    }
}
```

5. Change `register()` to `joinTopic()` — send `{"type":"join","pairing_code":"...","role":"daemon"}` instead of `{"type":"register","pairing_code":"..."}`

6. Add `reconnect()` method that re-establishes the TCP/WebSocket connection using stored host/port/path.

7. Store `self.member_id` from the `joined` response to use in relay messages.

- [ ] **Step 2: Verify build**

```bash
cd /Users/aneryu/kite && zig build
```

- [ ] **Step 3: Commit**

```bash
cd /Users/aneryu/kite && git add src/signal_client.zig
git commit -m "feat: signal client auto-reconnect with exponential backoff"
```

---

### Task 5: Kite — Multi-Peer Management & Protocol Adaptation

Replace `global_rtc_peer` singleton with a peer map. Adapt signal message handling for the new topic protocol.

**Files:**
- Modify: `src/main.zig:100-107,297-426,428-445,541-586,588-640`

- [ ] **Step 1: Replace global_rtc_peer with peer map**

Replace lines 100-107:

```zig
// Module-level mutable state for peer connections
var global_peers: std.StringHashMap(*RtcPeer) = undefined;
var global_peers_allocator: std.mem.Allocator = undefined;
var global_data_queue: *MessageQueue = undefined;
var global_state_queue: *MessageQueue = undefined;

fn initGlobalPeers(allocator: std.mem.Allocator, data_queue: *MessageQueue, state_queue: *MessageQueue) void {
    global_peers = std.StringHashMap(*RtcPeer).init(allocator);
    global_peers_allocator = allocator;
    global_data_queue = data_queue;
    global_state_queue = state_queue;
}

fn broadcastViaRtc(data: []const u8) void {
    var it = global_peers.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.*.send(data) catch {};
    }
}
```

- [ ] **Step 2: Update handleSignalMessage for new protocol**

Replace `handleSignalMessage` to handle `joined`, `member_joined`, `member_left`, and `relay` messages:

```zig
fn handleSignalMessage(
    allocator: std.mem.Allocator,
    raw: []const u8,
    session_manager: *SessionManager,
    auth: *Auth,
    data_queue: *MessageQueue,
    state_queue: *MessageQueue,
    config: Config,
) void {
    _ = auth;
    const parsed = std.json.parseFromSlice(struct {
        @"type": []const u8,
        member_id: ?[]const u8 = null,
        role: ?[]const u8 = null,
        from: ?[]const u8 = null,
        payload: ?[]const u8 = null,
        members: ?[]const u8 = null, // raw JSON array
    }, allocator, raw, .{ .ignore_unknown_fields = true }) catch {
        logStderr("[kite-signal] Failed to parse signal message", .{});
        return;
    };
    defer parsed.deinit();
    const msg = parsed.value;

    if (std.mem.eql(u8, msg.@"type", "joined")) {
        logStderr("[kite-signal] Joined topic, creating peers for existing browsers", .{});
        // Parse members array and create peers for browsers
        // The joined message contains the list of existing members
        // We need to parse the raw JSON to get member details
        createPeersForExistingMembers(allocator, raw, data_queue, state_queue, config);
        _ = session_manager;
    } else if (std.mem.eql(u8, msg.@"type", "member_joined")) {
        const role = msg.role orelse "";
        const member_id = msg.member_id orelse return;
        if (std.mem.eql(u8, role, "browser")) {
            logStderr("[kite-signal] Browser joined: {s}", .{member_id});
            createPeerForMember(allocator, member_id, data_queue, state_queue, config);
        }
    } else if (std.mem.eql(u8, msg.@"type", "member_left")) {
        const member_id = msg.member_id orelse return;
        logStderr("[kite-signal] Member left: {s}", .{member_id});
        destroyPeer(allocator, member_id);
    } else if (std.mem.eql(u8, msg.@"type", "relay")) {
        const from = msg.from orelse return;
        // The payload contains the actual SDP/ICE message
        // Route to the peer identified by 'from'
        handleRelayPayload(allocator, from, raw);
    }
}
```

- [ ] **Step 3: Add peer lifecycle helpers**

```zig
fn createPeerForMember(
    allocator: std.mem.Allocator,
    member_id: []const u8,
    data_queue: *MessageQueue,
    state_queue: *MessageQueue,
    config: Config,
) void {
    const peer = allocator.create(RtcPeer) catch return;
    peer.* = RtcPeer.init(allocator, data_queue, state_queue);
    peer.setupPeerConnection(.{
        .stun_server = config.stun_server,
        .turn_server = config.turn_server,
    }) catch {
        allocator.destroy(peer);
        return;
    };
    const key = allocator.dupe(u8, member_id) catch {
        peer.deinit();
        allocator.destroy(peer);
        return;
    };
    global_peers.put(key, peer) catch {
        allocator.free(key);
        peer.deinit();
        allocator.destroy(peer);
    };
}

fn destroyPeer(allocator: std.mem.Allocator, member_id: []const u8) void {
    if (global_peers.fetchRemove(member_id)) |entry| {
        entry.value.deinit();
        allocator.destroy(entry.value);
        allocator.free(entry.key);
    }
}
```

- [ ] **Step 4: Update handleRtcStateMessage to route via member_id**

The state messages (local_description, local_candidate) from a peer need to be relayed back to the correct browser via the signal server. Each `RtcPeer` should know its associated `member_id` so the relay can be addressed correctly.

Add `member_id` field to RtcPeer or use the state_queue message to include it.

Update `handleRtcStateMessage` to send `relay` messages with `to: member_id` instead of broadcasting.

- [ ] **Step 5: Update sendSessionsSync and handleDataChannelMessage**

Replace `global_rtc_peer` references with iteration over `global_peers`:

```zig
fn sendSessionsSync(allocator: std.mem.Allocator, session_manager: *SessionManager, auth: *Auth) void {
    _ = auth;
    // ... (same JSON building code) ...

    var it = global_peers.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.*.send(json_buf.items) catch {};
    }
}
```

For `handleDataChannelMessage`, input from any peer is handled the same way (first-come-first-served to PTY). The only change is sending responses to the correct peer rather than the global singleton.

- [ ] **Step 6: Update runStart cleanup**

Replace the cleanup section at the end of `runStart` (lines 267-273):

```zig
// Cleanup all peers
var it = global_peers.iterator();
while (it.next()) |entry| {
    entry.value_ptr.*.deinit();
    allocator.destroy(entry.value_ptr.*);
    allocator.free(entry.key);
}
global_peers.deinit();
rtc_mod.cleanup();
```

- [ ] **Step 7: Verify build**

```bash
cd /Users/aneryu/kite && zig build
```

- [ ] **Step 8: Commit**

```bash
cd /Users/aneryu/kite && git add src/main.zig src/rtc.zig
git commit -m "feat: multi-peer management with topic-based signal protocol"
```

---

### Task 6: QR Code Module

Create a pure Zig QR code encoder + terminal renderer.

**Files:**
- Create: `src/qr.zig`

- [ ] **Step 1: Create qr.zig with QR encoding + terminal rendering**

Create `src/qr.zig` implementing:

1. **Data encoding** — byte mode for arbitrary URL strings
2. **Error correction** — Reed-Solomon with Low ECC level
3. **Matrix construction** — finder patterns, timing, format info, data placement
4. **Masking** — evaluate all 8 masks, pick best penalty score
5. **Terminal rendering** — Unicode block chars (`█▀▄ `) with 2 pixel rows per char row

Public interface:

```zig
pub const QrCode = struct {
    modules: [MAX_SIZE * MAX_SIZE]bool,
    size: usize,
};

pub fn encode(data: []const u8) !QrCode { ... }

pub fn renderTerminal(writer: anytype, qr: QrCode, indent: []const u8) !void { ... }
```

Scope constraints:
- Version 2-4 only (17-33 modules, up to 78 bytes Low ECC)
- Byte mode encoding only
- Low error correction level only
- ~400-500 lines total

This is a self-contained module with no dependencies on the rest of the codebase.

The implementation must include:
- GF(2^8) arithmetic (multiply, polynomial division)
- Reed-Solomon error correction code generation
- QR matrix layout (finder, timing, alignment, format info)
- Data bit placement with masking
- Penalty score calculation for mask selection
- Terminal output using `▀`, `▄`, `█`, ` ` Unicode block elements

- [ ] **Step 2: Add test**

At the bottom of `src/qr.zig`:

```zig
test "qr encode short url" {
    const qr = try encode("https://relay.fun.dev/#/pair/abc123:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789");
    try std.testing.expect(qr.size >= 21); // at least version 1
    try std.testing.expect(qr.size <= 33); // at most version 4
}
```

- [ ] **Step 3: Run test**

```bash
cd /Users/aneryu/kite && zig build test
```

- [ ] **Step 4: Commit**

```bash
cd /Users/aneryu/kite && git add src/qr.zig
git commit -m "feat: add pure Zig QR code encoder and terminal renderer"
```

---

### Task 7: Kite — Extend `kite status` with QR Code

**Files:**
- Modify: `src/main.zig:1197-1211` (runStatus function)

- [ ] **Step 1: Rewrite runStatus**

Replace `runStatus` to read config and display QR code:

```zig
fn runStatus(allocator: std.mem.Allocator) !void {
    const stdout_file = std.fs.File.stdout();
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    const is_running = blk: {
        const stream = std.net.connectUnixSocket(hooks.IPC_SOCKET_PATH) catch break :blk false;
        stream.close();
        break :blk true;
    };

    if (is_running) {
        try stdout.print("\n  kite is running\n\n", .{});
    } else {
        try stdout.print("\n  kite is not running\n\n", .{});
    }

    const file_config = readConfigFile(allocator) orelse {
        try stdout.print("  No config found. Run 'kite setup' first.\n\n", .{});
        try stdout.flush();
        return;
    };

    if (file_config.pairing_code.len != 6 or file_config.setup_secret.len != 64) {
        try stdout.print("  No pairing code configured. Run 'kite start' to generate one.\n\n", .{});
        try stdout.flush();
        return;
    }

    try stdout.print("  Signal server: {s}\n", .{file_config.signal_url});
    try stdout.print("  Pairing code:  {s}\n\n", .{file_config.pairing_code});

    // Build pairing URL
    const http_url = if (std.mem.startsWith(u8, file_config.signal_url, "wss://"))
        try std.fmt.allocPrint(allocator, "https://{s}", .{file_config.signal_url[6..]})
    else if (std.mem.startsWith(u8, file_config.signal_url, "ws://"))
        try std.fmt.allocPrint(allocator, "http://{s}", .{file_config.signal_url[5..]})
    else
        try allocator.dupe(u8, file_config.signal_url);
    defer allocator.free(http_url);

    const pairing_url = try std.fmt.allocPrint(allocator, "{s}/#/pair/{s}:{s}", .{ http_url, file_config.pairing_code, file_config.setup_secret });
    defer allocator.free(pairing_url);

    // Render QR code
    const qr_mod = @import("qr.zig");
    if (qr_mod.encode(pairing_url)) |qr| {
        try qr_mod.renderTerminal(stdout, qr, "  ");
        try stdout.print("\n", .{});
    } else |_| {}

    try stdout.print("  {s}\n\n", .{pairing_url});
    try stdout.flush();
}
```

Also update the `runStatus` call in `main` to pass allocator:
Line 59: `try runStatus(allocator);` → update signature to accept allocator.

- [ ] **Step 2: Verify build**

```bash
cd /Users/aneryu/kite && zig build
```

- [ ] **Step 3: Commit**

```bash
cd /Users/aneryu/kite && git add src/main.zig
git commit -m "feat: kite status shows QR code and pairing URL from config"
```

---

### Task 8: Web — Signal Protocol Adaptation

Update the signal client to use the new topic-based protocol.

**Files:**
- Modify: `web/src/lib/signal.ts`

- [ ] **Step 1: Rewrite signal.ts**

Replace the entire contents of `web/src/lib/signal.ts`:

```typescript
export interface SignalMessage {
  type: string;
  member_id?: string;
  role?: string;
  from?: string;
  to?: string;
  payload?: Record<string, unknown>;
  members?: Array<{ id: string; role: string }>;
  error?: string;
  [key: string]: unknown;
}

export type SignalMessageHandler = (msg: SignalMessage) => void;

export class SignalClient {
  private ws: WebSocket | null = null;
  private handlers: SignalMessageHandler[] = [];
  private reconnectTimer: number | null = null;
  private reconnectDelay = 2000;
  private maxReconnectDelay = 30000;
  private url: string;
  private pairingCode: string;
  private role: string;
  public memberID: string = '';

  constructor(url: string, pairingCode: string, role: string = 'browser') {
    this.url = url;
    this.pairingCode = pairingCode;
    this.role = role;
  }

  connect(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (this.ws?.readyState === WebSocket.OPEN) { resolve(); return; }
      this.ws = new WebSocket(this.url);
      this.ws.onopen = () => {
        this.send({ type: 'join', pairing_code: this.pairingCode, role: this.role });
        this.reconnectDelay = 2000; // reset backoff
        resolve();
      };
      this.ws.onmessage = (ev) => {
        try {
          const msg: SignalMessage = JSON.parse(ev.data);
          if (msg.type === 'joined' && msg.member_id) {
            this.memberID = msg.member_id;
          }
          this.handlers.forEach((h) => h(msg));
        } catch {}
      };
      this.ws.onclose = () => this.scheduleReconnect();
      this.ws.onerror = () => {
        this.ws?.close();
        reject(new Error('WebSocket error'));
      };
    });
  }

  private scheduleReconnect() {
    if (this.reconnectTimer) return;
    this.reconnectTimer = window.setTimeout(() => {
      this.reconnectTimer = null;
      this.connect().catch(() => {
        // Increase backoff on failure
        this.reconnectDelay = Math.min(this.reconnectDelay * 2, this.maxReconnectDelay);
      });
    }, this.reconnectDelay);
  }

  onMessage(handler: SignalMessageHandler): () => void {
    this.handlers.push(handler);
    return () => { this.handlers = this.handlers.filter((h) => h !== handler); };
  }

  /** Send a relay message to a specific member */
  relay(to: string, payload: Record<string, unknown>): void {
    this.send({ type: 'relay', to, payload });
  }

  /** Send a broadcast message to all other members */
  broadcast(payload: Record<string, unknown>): void {
    this.send({ type: 'broadcast', payload });
  }

  private send(msg: Record<string, unknown>) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(msg));
    }
  }

  disconnect() {
    if (this.reconnectTimer) { clearTimeout(this.reconnectTimer); this.reconnectTimer = null; }
    this.ws?.close();
    this.ws = null;
  }
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/aneryu/kite && git add web/src/lib/signal.ts
git commit -m "refactor(web): adapt signal client to topic-based protocol"
```

---

### Task 9: Web — WebRTC Reconnect & Multi-Daemon Support

Update webrtc.ts to handle member-based signaling with reconnection.

**Files:**
- Modify: `web/src/lib/webrtc.ts`

- [ ] **Step 1: Rewrite webrtc.ts**

Replace the entire contents of `web/src/lib/webrtc.ts`:

```typescript
import type { ServerMessage } from './types';
import { SignalClient } from './signal';

type MessageHandler = (msg: ServerMessage) => void;

export class RtcManager {
  private pc: RTCPeerConnection | null = null;
  private dc: RTCDataChannel | null = null;
  private signal: SignalClient | null = null;
  private handlers: MessageHandler[] = [];
  private authenticated: boolean = false;
  private pingInterval: number | null = null;
  private pendingCandidates: { candidate: string; mid: string }[] = [];
  private remoteDescriptionSet = false;
  private daemonMemberID: string | null = null;
  private stunServer: string = 'stun:stun.l.google.com:19302';
  private storedToken: string | null = null;

  async connect(signalUrl: string, pairingCode: string, stunServer?: string): Promise<void> {
    if (stunServer) this.stunServer = stunServer;
    this.signal = new SignalClient(signalUrl, pairingCode, 'browser');

    this.signal.onMessage((msg) => {
      switch (msg.type) {
        case 'joined':
          // Check if daemon is already in the topic
          this.daemonMemberID = null;
          if (msg.members) {
            const daemon = msg.members.find((m) => m.role === 'daemon');
            if (daemon) {
              this.daemonMemberID = daemon.id;
              this.startWebRTC();
            }
            // else: no daemon yet, wait for member_joined
          }
          this.handlers.forEach((h) => h({ type: 'signal_connected' }));
          break;
        case 'member_joined':
          if (msg.role === 'daemon' && msg.member_id) {
            this.daemonMemberID = msg.member_id;
            this.startWebRTC();
          }
          break;
        case 'member_left':
          if (msg.member_id === this.daemonMemberID) {
            this.handlePeerLeft();
            this.daemonMemberID = null;
            this.handlers.forEach((h) => h({ type: 'daemon_disconnected' }));
          }
          break;
        case 'relay':
          if (msg.payload) {
            this.handleRelayedMessage(msg.payload);
          }
          break;
        case 'error':
          console.error('[RTC] Signal error:', msg.error);
          break;
      }
    });

    await this.signal.connect();
  }

  onMessage(handler: MessageHandler): () => void {
    this.handlers.push(handler);
    return () => { this.handlers = this.handlers.filter((h) => h !== handler); };
  }

  authenticate(token: string): void {
    this.storedToken = token;
    this.authenticated = true;
    this.sendRaw({ type: 'auth', token });
  }

  sendTerminalInput(data: string, sessionId: number): void {
    this.sendRaw({ type: 'terminal_input', data, session_id: sessionId });
  }

  sendResize(cols: number, rows: number, sessionId: number): void {
    this.sendRaw({ type: 'resize', cols, rows, session_id: sessionId });
  }

  sendPromptResponse(text: string, sessionId: number): void {
    this.sendRaw({ type: 'prompt_response', text, session_id: sessionId });
  }

  createSession(command?: string): void {
    this.sendRaw({ type: 'create_session', data: command || 'claude' });
  }

  deleteSession(sessionId: number): void {
    this.sendRaw({ type: 'delete_session', session_id: sessionId });
  }

  isOpen(): boolean {
    return this.dc?.readyState === 'open';
  }

  disconnect(): void {
    this.stopPing();
    this.dc?.close();
    this.dc = null;
    this.pc?.close();
    this.pc = null;
    this.signal?.disconnect();
    this.signal = null;
    this.authenticated = false;
    this.daemonMemberID = null;
  }

  // --- Private ---

  private startWebRTC(): void {
    // Clean up any existing connection
    this.stopPing();
    this.dc?.close();
    this.pc?.close();
    this.remoteDescriptionSet = false;
    this.pendingCandidates = [];

    const iceServers: RTCIceServer[] = [{ urls: this.stunServer }];
    this.pc = new RTCPeerConnection({ iceServers });
    this.dc = this.pc.createDataChannel('kite', { ordered: true });

    this.dc.onopen = () => {
      console.log('[RTC] DataChannel open');
      this.startPing();
      // Auto re-authenticate if we have a stored token
      if (this.storedToken) {
        this.sendRaw({ type: 'auth', token: this.storedToken });
      }
    };

    this.dc.onmessage = (ev) => {
      try {
        const raw = typeof ev.data === 'string' ? ev.data : new TextDecoder().decode(ev.data);
        const msg: ServerMessage = JSON.parse(raw);
        if (msg.type === 'pong') return;
        this.handlers.forEach((h) => h(msg));
      } catch (e) {
        console.error('[RTC] DC message parse error:', e);
      }
    };

    this.dc.onclose = () => {
      console.log('[RTC] DataChannel closed');
      this.stopPing();
    };

    this.pc.onicecandidate = (ev) => {
      if (ev.candidate && this.signal && this.daemonMemberID) {
        this.signal.relay(this.daemonMemberID, {
          type: 'ice_candidate',
          candidate: ev.candidate.candidate,
          mid: ev.candidate.sdpMid || '',
        });
      }
    };

    this.pc.onconnectionstatechange = () => {
      const state = this.pc?.connectionState;
      console.log('[RTC] Connection state:', state);
      if (state === 'disconnected' || state === 'failed') {
        this.handlePeerLeft();
      }
    };

    this.pc.createOffer()
      .then((offer) => this.pc!.setLocalDescription(offer))
      .then(() => {
        if (this.pc?.localDescription && this.signal && this.daemonMemberID) {
          this.signal.relay(this.daemonMemberID, {
            type: 'sdp_offer',
            sdp: this.pc.localDescription.sdp,
            sdp_type: this.pc.localDescription.type,
          });
        }
      })
      .catch((err) => console.error('[RTC] Offer error:', err));
  }

  private handleRelayedMessage(payload: Record<string, unknown>): void {
    const type = payload.type as string;
    if (type === 'sdp_answer') {
      this.handleSdpAnswer(payload.sdp as string, payload.sdp_type as RTCSdpType);
    } else if (type === 'ice_candidate') {
      this.handleRemoteCandidate(payload.candidate as string, payload.mid as string);
    }
  }

  private async handleSdpAnswer(sdp: string, sdpType: RTCSdpType): Promise<void> {
    if (!this.pc) return;
    try {
      await this.pc.setRemoteDescription(new RTCSessionDescription({ sdp, type: sdpType }));
      this.remoteDescriptionSet = true;
      for (const c of this.pendingCandidates) {
        await this.pc.addIceCandidate(new RTCIceCandidate({ candidate: c.candidate, sdpMid: c.mid }));
      }
      this.pendingCandidates = [];
    } catch (err) {
      console.error('[RTC] setRemoteDescription error:', err);
    }
  }

  private async handleRemoteCandidate(candidate: string, mid: string): Promise<void> {
    if (!this.pc) return;
    if (!this.remoteDescriptionSet) {
      this.pendingCandidates.push({ candidate, mid });
      return;
    }
    try {
      await this.pc.addIceCandidate(new RTCIceCandidate({ candidate, sdpMid: mid }));
    } catch (err) {
      console.error('[RTC] addIceCandidate error:', err);
    }
  }

  private handlePeerLeft(): void {
    this.stopPing();
    this.dc?.close();
    this.dc = null;
    this.pc?.close();
    this.pc = null;
    this.remoteDescriptionSet = false;
    this.pendingCandidates = [];
    this.handlers.forEach((h) => h({ type: 'disconnected' }));
  }

  private startPing(): void {
    this.stopPing();
    this.pingInterval = window.setInterval(() => {
      this.sendRaw({ type: 'ping' });
    }, 10_000);
  }

  private stopPing(): void {
    if (this.pingInterval !== null) {
      clearInterval(this.pingInterval);
      this.pingInterval = null;
    }
  }

  private sendRaw(msg: Record<string, unknown>): void {
    if (this.dc?.readyState === 'open') {
      this.dc.send(JSON.stringify(msg));
    }
  }
}

export const rtc = new RtcManager();
```

Key changes:
- Uses `relay(to, payload)` instead of direct send for SDP/ICE
- Tracks `daemonMemberID` from `joined` members list or `member_joined`
- On `joined`: checks if daemon already in topic, starts WebRTC if so
- On `member_joined` (daemon): starts WebRTC
- On `member_left` (daemon): handles peer left
- On reconnect: DataChannel `onopen` auto-re-authenticates with stored token
- Emits `signal_connected` and `daemon_disconnected` events for App.svelte

- [ ] **Step 2: Commit**

```bash
cd /Users/aneryu/kite && git add web/src/lib/webrtc.ts
git commit -m "feat(web): WebRTC reconnect with topic-based signaling"
```

---

### Task 10: Web — App Auth Flow & Reconnect UX

Update App.svelte for persistent auth, no localStorage clearing, and waiting states.

**Files:**
- Modify: `web/src/App.svelte`

- [ ] **Step 1: Update initializeAuth**

Key changes to `web/src/App.svelte`:

1. Don't clear localStorage on transient failures (remove lines 95-96, 101-103)
2. Add handling for `signal_connected` and `daemon_disconnected` events
3. Add "Waiting for daemon..." state
4. On `auth_result` failure, only clear if explicitly rejected (not on timeout)
5. On DataChannel reopen, auto-re-authenticate (handled in webrtc.ts)

Update the `initializeAuth` function — on timeout/failure, keep localStorage and show reconnecting:

```typescript
async function initializeAuth() {
    const pairing = parsePairingFromHash();
    if (pairing) {
      clearPairingFromHash();
      connecting = true;
      try {
        await rtc.connect(signalUrl, pairing.pairingCode);
        setStoredPairingCode(pairing.pairingCode);
        setStoredToken(pairing.setupSecret); // store setup secret as token for re-auth
        if (await waitForOpen()) {
          rtc.authenticate(pairing.setupSecret);
        } else {
          // Don't clear — daemon may come online later
          connecting = false;
          waitingForDaemon = true;
        }
      } catch {
        connecting = false;
        authError = 'Failed to connect to signal server.';
        authRequired = true;
      }
      return;
    }

    const storedToken = getStoredToken();
    const storedCode = getStoredPairingCode();
    if (storedToken && storedCode) {
      connecting = true;
      try {
        await rtc.connect(signalUrl, storedCode);
        if (await waitForOpen()) {
          rtc.authenticate(storedToken);
        } else {
          // Keep credentials, show waiting state
          connecting = false;
          waitingForDaemon = true;
        }
      } catch {
        connecting = false;
        authError = 'Failed to connect to signal server.';
        authRequired = true;
      }
      return;
    }

    authRequired = true;
  }
```

2. Add `waitingForDaemon` state variable and handle new events:

```typescript
let waitingForDaemon = $state(false);

// In onMount, add handlers for new events:
onMount(() => {
    const unsubAuth = rtc.onMessage(handleAuthResult);
    const unsubSignal = rtc.onMessage((msg) => {
      if (msg.type === 'signal_connected') {
        // Signal reconnected, waiting for daemon
        waitingForDaemon = true;
        connecting = false;
      } else if (msg.type === 'daemon_disconnected') {
        waitingForDaemon = true;
        authReady = false;
      } else if (msg.type === 'auth_result' && msg.success) {
        waitingForDaemon = false;
      }
    });

    void initializeAuth();

    return () => {
      unsubAuth();
      unsubSignal();
      rtc.disconnect();
    };
});
```

3. In the `handleAuthResult` function, only clear on explicit rejection:

```typescript
function handleAuthResult(msg: import('./lib/types').ServerMessage) {
    if (msg.type !== 'auth_result') return;
    connecting = false;
    if (msg.success) {
      if (msg.token) setStoredToken(msg.token as string);
      authReady = true;
      authRequired = false;
      waitingForDaemon = false;
      authError = '';
    } else {
      // Auth explicitly rejected — credentials are invalid
      clearStoredToken();
      clearStoredPairingCode();
      authReady = false;
      authRequired = true;
      waitingForDaemon = false;
      authError = 'Authentication failed. Please re-pair.';
    }
  }
```

4. Add waiting state to the template (after the existing `connecting` check):

```svelte
{#if waitingForDaemon}
  <div class="status">Waiting for daemon...</div>
{/if}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/aneryu/kite && git add web/src/App.svelte
git commit -m "feat(web): persistent auth flow with reconnect and waiting states"
```

---

### Task 11: Final Integration & Verification

- [ ] **Step 1: Build web frontend**

```bash
cd /Users/aneryu/kite/web && npm run build
```

Expected: builds successfully.

- [ ] **Step 2: Build Zig backend**

```bash
cd /Users/aneryu/kite && zig build
```

Expected: builds successfully.

- [ ] **Step 3: Run Zig tests**

```bash
cd /Users/aneryu/kite && zig build test
```

Expected: all tests pass.

- [ ] **Step 4: Run Go tests**

```bash
cd /Users/aneryu/kite/signal && go test ./... -v
```

Expected: all tests pass.

- [ ] **Step 5: Review git log**

```bash
git log --oneline -15
```

Expected: commits for each task in order.
