package signal

import (
	"embed"
	"encoding/json"
	"io/fs"
	"log"
	"net"
	"net/http"
	"time"

	"github.com/gorilla/websocket"
)

//go:embed static
var staticFiles embed.FS

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

// wsConn wraps a gorilla WebSocket connection to implement the Sender interface.
type wsConn struct {
	conn *websocket.Conn
}

func (w *wsConn) Send(data []byte) error {
	return w.conn.WriteMessage(websocket.TextMessage, data)
}

// signalMsg is the initial message sent by a client to identify itself.
type signalMsg struct {
	Type        string `json:"type"`
	PairingCode string `json:"pairingCode"`
}

// Handler handles HTTP and WebSocket requests for the signal server.
type Handler struct {
	rm       *RoomManager
	staticFS http.Handler
	mux      *http.ServeMux
}

// NewHandler creates a new Handler with the given RoomManager and static file directory.
// If staticDir is empty, the embedded static files are used.
func NewHandler(rm *RoomManager, staticDir string) http.Handler {
	h := &Handler{
		rm:  rm,
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

	// Read first message to determine client type
	_, data, err := ws.ReadMessage()
	if err != nil {
		log.Printf("read first message: %v", err)
		return
	}

	var msg signalMsg
	if err := json.Unmarshal(data, &msg); err != nil {
		ws.WriteMessage(websocket.TextMessage, []byte(`{"type":"error","error":"invalid message"}`))
		return
	}

	conn := &wsConn{conn: ws}

	switch msg.Type {
	case "register":
		h.handleDaemon(ws, conn, msg.PairingCode)
	case "join":
		h.handleBrowser(ws, conn, msg.PairingCode, clientIP(r))
	default:
		ws.WriteMessage(websocket.TextMessage, []byte(`{"type":"error","error":"unknown message type"}`))
	}
}

func (h *Handler) handleDaemon(ws *websocket.Conn, conn *wsConn, pairingCode string) {
	if err := h.rm.Register(pairingCode, conn); err != nil {
		errMsg, _ := json.Marshal(map[string]string{"type": "error", "error": err.Error()})
		ws.WriteMessage(websocket.TextMessage, errMsg)
		return
	}
	defer h.rm.DaemonDisconnected(pairingCode)

	// Send registration confirmation
	ws.WriteMessage(websocket.TextMessage, []byte(`{"type":"registered"}`))

	// Start ping ticker
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	go func() {
		for range ticker.C {
			if err := ws.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}()

	// Relay loop: forward messages from daemon to browser
	for {
		_, data, err := ws.ReadMessage()
		if err != nil {
			return
		}
		if err := h.rm.RelayFromDaemon(pairingCode, data); err != nil {
			// Browser not connected yet or room gone; just continue
			if err == ErrRoomNotFound {
				return
			}
		}
	}
}

func (h *Handler) handleBrowser(ws *websocket.Conn, conn *wsConn, pairingCode string, ip string) {
	if err := h.rm.Join(pairingCode, conn, ip); err != nil {
		errMsg, _ := json.Marshal(map[string]string{"type": "error", "error": err.Error()})
		ws.WriteMessage(websocket.TextMessage, errMsg)
		return
	}
	defer h.rm.BrowserDisconnected(pairingCode)

	// Send join confirmation
	ws.WriteMessage(websocket.TextMessage, []byte(`{"type":"joined"}`))

	// Start ping ticker
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	go func() {
		for range ticker.C {
			if err := ws.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}()

	// Relay loop: forward messages from browser to daemon
	for {
		_, data, err := ws.ReadMessage()
		if err != nil {
			return
		}
		if err := h.rm.RelayFromBrowser(pairingCode, data); err != nil {
			if err == ErrRoomNotFound {
				return
			}
		}
	}
}

// clientIP extracts the client IP from the request, checking X-Forwarded-For first.
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
