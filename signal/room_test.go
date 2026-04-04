package signal

import (
	"errors"
	"sync"
	"testing"
	"time"
)

// mockSender records messages sent to it.
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

func TestRegisterAndJoin(t *testing.T) {
	rm := NewRoomManager()
	daemon := newMockSender()
	browser := newMockSender()

	if err := rm.Register("ABCDEF", daemon); err != nil {
		t.Fatalf("Register: %v", err)
	}

	if err := rm.Join("ABCDEF", browser, "1.2.3.4"); err != nil {
		t.Fatalf("Join: %v", err)
	}

	// Daemon should receive peer_joined notification
	msgs := daemon.Messages()
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message to daemon, got %d", len(msgs))
	}
	if string(msgs[0]) != `{"type":"peer_joined"}` {
		t.Errorf("unexpected notification: %s", msgs[0])
	}
}

func TestJoinNonexistent(t *testing.T) {
	rm := NewRoomManager()
	browser := newMockSender()

	err := rm.Join("NOPE00", browser, "1.2.3.4")
	if !errors.Is(err, ErrRoomNotFound) {
		t.Fatalf("expected ErrRoomNotFound, got %v", err)
	}
}

func TestDuplicateRegister(t *testing.T) {
	rm := NewRoomManager()
	daemon := newMockSender()

	if err := rm.Register("ABCDEF", daemon); err != nil {
		t.Fatalf("Register: %v", err)
	}

	err := rm.Register("ABCDEF", newMockSender())
	if !errors.Is(err, ErrRoomExists) {
		t.Fatalf("expected ErrRoomExists, got %v", err)
	}
}

func TestRoomLocking(t *testing.T) {
	rm := NewRoomManager()
	daemon := newMockSender()
	browser1 := newMockSender()
	browser2 := newMockSender()

	rm.Register("ABCDEF", daemon)
	rm.Join("ABCDEF", browser1, "1.2.3.4")

	// Room should be locked now; second browser cannot join
	err := rm.Join("ABCDEF", browser2, "5.6.7.8")
	if !errors.Is(err, ErrRoomLocked) {
		t.Fatalf("expected ErrRoomLocked, got %v", err)
	}
}

func TestRelay(t *testing.T) {
	rm := NewRoomManager()
	daemon := newMockSender()
	browser := newMockSender()

	rm.Register("ABCDEF", daemon)
	rm.Join("ABCDEF", browser, "1.2.3.4")

	// Browser -> Daemon
	if err := rm.RelayFromBrowser("ABCDEF", []byte(`{"sdp":"offer"}`)); err != nil {
		t.Fatalf("RelayFromBrowser: %v", err)
	}
	dmsgs := daemon.Messages()
	// peer_joined + relayed message
	if len(dmsgs) != 2 {
		t.Fatalf("expected 2 messages to daemon, got %d", len(dmsgs))
	}
	if string(dmsgs[1]) != `{"sdp":"offer"}` {
		t.Errorf("unexpected relay to daemon: %s", dmsgs[1])
	}

	// Daemon -> Browser
	if err := rm.RelayFromDaemon("ABCDEF", []byte(`{"sdp":"answer"}`)); err != nil {
		t.Fatalf("RelayFromDaemon: %v", err)
	}
	bmsgs := browser.Messages()
	if len(bmsgs) != 1 {
		t.Fatalf("expected 1 message to browser, got %d", len(bmsgs))
	}
	if string(bmsgs[0]) != `{"sdp":"answer"}` {
		t.Errorf("unexpected relay to browser: %s", bmsgs[0])
	}
}

func TestRelayNoPeer(t *testing.T) {
	rm := NewRoomManager()
	daemon := newMockSender()

	rm.Register("ABCDEF", daemon)

	// No browser yet, relay from daemon should fail
	err := rm.RelayFromDaemon("ABCDEF", []byte(`hello`))
	if !errors.Is(err, ErrNoPeer) {
		t.Fatalf("expected ErrNoPeer, got %v", err)
	}
}

func TestDaemonDisconnect(t *testing.T) {
	rm := NewRoomManager()
	daemon := newMockSender()
	browser := newMockSender()

	rm.Register("ABCDEF", daemon)
	rm.Join("ABCDEF", browser, "1.2.3.4")

	rm.DaemonDisconnected("ABCDEF")

	// Browser should receive peer_left notification
	bmsgs := browser.Messages()
	if len(bmsgs) != 1 {
		t.Fatalf("expected 1 message to browser, got %d", len(bmsgs))
	}
	if string(bmsgs[0]) != `{"type":"peer_left"}` {
		t.Errorf("unexpected notification: %s", bmsgs[0])
	}

	// Room should be destroyed
	err := rm.Join("ABCDEF", newMockSender(), "1.2.3.4")
	if !errors.Is(err, ErrRoomNotFound) {
		t.Fatalf("expected room to be destroyed, got %v", err)
	}
}

func TestBrowserDisconnect(t *testing.T) {
	rm := NewRoomManager()
	daemon := newMockSender()
	browser := newMockSender()

	rm.Register("ABCDEF", daemon)
	rm.Join("ABCDEF", browser, "1.2.3.4")

	rm.BrowserDisconnected("ABCDEF")

	// Daemon should receive peer_joined then peer_left
	dmsgs := daemon.Messages()
	if len(dmsgs) != 2 {
		t.Fatalf("expected 2 messages to daemon, got %d", len(dmsgs))
	}
	if string(dmsgs[1]) != `{"type":"peer_left"}` {
		t.Errorf("unexpected notification: %s", dmsgs[1])
	}

	// Room should be unlocked; a new browser can join
	browser2 := newMockSender()
	if err := rm.Join("ABCDEF", browser2, "5.6.7.8"); err != nil {
		t.Fatalf("expected room to be unlocked after browser disconnect: %v", err)
	}
}

func TestCleanupStale(t *testing.T) {
	rm := NewRoomManager()
	rm.roomTTL = 50 * time.Millisecond

	daemon := newMockSender()
	rm.Register("STALE1", daemon)

	time.Sleep(100 * time.Millisecond)

	rm.CleanupStale()

	err := rm.Join("STALE1", newMockSender(), "1.2.3.4")
	if !errors.Is(err, ErrRoomNotFound) {
		t.Fatalf("expected stale room to be cleaned up, got %v", err)
	}
}

func TestRateLimit(t *testing.T) {
	rm := NewRoomManager()
	rm.maxJoinAttempts = 3 // lower for testing

	daemon := newMockSender()
	rm.Register("ROOM01", daemon)
	rm.Register("ROOM02", newMockSender())
	rm.Register("ROOM03", newMockSender())
	rm.Register("ROOM04", newMockSender())

	ip := "10.0.0.1"

	// Use up the rate limit on nonexistent rooms
	for i := 0; i < 3; i++ {
		rm.Join("NOPE0"+string(rune('0'+i)), newMockSender(), ip)
	}

	// Next attempt should be rate limited
	err := rm.Join("ROOM01", newMockSender(), ip)
	if !errors.Is(err, ErrRateLimited) {
		t.Fatalf("expected ErrRateLimited, got %v", err)
	}
}

func TestConcurrentAccess(t *testing.T) {
	rm := NewRoomManager()
	var wg sync.WaitGroup

	// Register many rooms concurrently
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			code := "RM" + string(rune('A'+i/26)) + string(rune('A'+i%26)) + "00"
			rm.Register(code, newMockSender())
		}(i)
	}
	wg.Wait()
}
