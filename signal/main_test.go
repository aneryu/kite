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

func TestWSRegisterAndJoin(t *testing.T) {
	rm := NewRoomManager()
	handler := NewHandler(rm, "")
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// Daemon registers
	daemon := dial(t, wsURL(srv))
	defer daemon.Close()

	sendJSON(t, daemon, signalMsg{Type: "register", PairingCode: "TEST01"})

	msg := readJSON(t, daemon)
	if msg["type"] != "registered" {
		t.Fatalf("expected registered, got %v", msg["type"])
	}

	// Browser joins
	browser := dial(t, wsURL(srv))
	defer browser.Close()

	sendJSON(t, browser, signalMsg{Type: "join", PairingCode: "TEST01"})

	joinMsg := readJSON(t, browser)
	if joinMsg["type"] != "joined" {
		t.Fatalf("expected joined, got %v", joinMsg["type"])
	}

	// Daemon should receive peer_joined
	peerMsg := readJSON(t, daemon)
	if peerMsg["type"] != "peer_joined" {
		t.Fatalf("expected peer_joined, got %v", peerMsg["type"])
	}
}

func TestWSJoinNonexistentRoom(t *testing.T) {
	rm := NewRoomManager()
	handler := NewHandler(rm, "")
	srv := httptest.NewServer(handler)
	defer srv.Close()

	browser := dial(t, wsURL(srv))
	defer browser.Close()

	sendJSON(t, browser, signalMsg{Type: "join", PairingCode: "NOPE00"})

	msg := readJSON(t, browser)
	if msg["type"] != "error" {
		t.Fatalf("expected error, got %v", msg["type"])
	}
	if msg["error"] != "room not found" {
		t.Fatalf("expected 'room not found', got %v", msg["error"])
	}
}

func TestWSSDPRelay(t *testing.T) {
	rm := NewRoomManager()
	handler := NewHandler(rm, "")
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// Daemon registers
	daemon := dial(t, wsURL(srv))
	defer daemon.Close()

	sendJSON(t, daemon, signalMsg{Type: "register", PairingCode: "RELAY1"})
	readJSON(t, daemon) // registered

	// Browser joins
	browser := dial(t, wsURL(srv))
	defer browser.Close()

	sendJSON(t, browser, signalMsg{Type: "join", PairingCode: "RELAY1"})
	readJSON(t, browser) // joined
	readJSON(t, daemon)  // peer_joined

	// Browser sends SDP offer to daemon
	offer := map[string]string{"type": "offer", "sdp": "v=0\r\n..."}
	sendJSON(t, browser, offer)

	relayed := readJSON(t, daemon)
	if relayed["type"] != "offer" {
		t.Fatalf("expected offer relayed to daemon, got %v", relayed["type"])
	}
	if relayed["sdp"] != "v=0\r\n..." {
		t.Fatalf("unexpected sdp: %v", relayed["sdp"])
	}

	// Daemon sends SDP answer to browser
	answer := map[string]string{"type": "answer", "sdp": "v=0\r\nanswer..."}
	sendJSON(t, daemon, answer)

	relayed = readJSON(t, browser)
	if relayed["type"] != "answer" {
		t.Fatalf("expected answer relayed to browser, got %v", relayed["type"])
	}
	if relayed["sdp"] != "v=0\r\nanswer..." {
		t.Fatalf("unexpected sdp: %v", relayed["sdp"])
	}
}

func TestWSDaemonDisconnectNotifiesBrowser(t *testing.T) {
	rm := NewRoomManager()
	handler := NewHandler(rm, "")
	srv := httptest.NewServer(handler)
	defer srv.Close()

	daemon := dial(t, wsURL(srv))
	sendJSON(t, daemon, signalMsg{Type: "register", PairingCode: "DISC01"})
	readJSON(t, daemon) // registered

	browser := dial(t, wsURL(srv))
	defer browser.Close()

	sendJSON(t, browser, signalMsg{Type: "join", PairingCode: "DISC01"})
	readJSON(t, browser) // joined
	readJSON(t, daemon)  // peer_joined

	// Daemon disconnects
	daemon.Close()

	// Browser should receive peer_left
	msg := readJSON(t, browser)
	if msg["type"] != "peer_left" {
		t.Fatalf("expected peer_left, got %v", msg["type"])
	}
}
