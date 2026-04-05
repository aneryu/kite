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

	log.Printf("[signal] %s first message: %s (parsed: type=%q code=%q role=%q)", ip, string(data), msg.Type, msg.PairingCode, msg.Role)

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
