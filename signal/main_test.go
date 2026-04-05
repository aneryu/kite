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
