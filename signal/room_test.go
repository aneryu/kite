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
