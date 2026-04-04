package signal

import (
	"errors"
	"sync"
	"time"
)

var (
	ErrRoomExists   = errors.New("room already exists")
	ErrRoomNotFound = errors.New("room not found")
	ErrRoomLocked   = errors.New("room is locked")
	ErrRateLimited  = errors.New("rate limited")
	ErrNoPeer       = errors.New("no peer connected")
)

// Sender is the interface for sending data to a WebSocket connection.
type Sender interface {
	Send(data []byte) error
}

// Room represents a signaling room pairing a daemon and a browser.
type Room struct {
	PairingCode string
	Daemon      Sender
	Browser     Sender
	Locked      bool
	LastActive  time.Time
}

type rateLimitEntry struct {
	count    int
	windowAt time.Time
}

// RoomManager manages signaling rooms with thread-safe access.
type RoomManager struct {
	mu    sync.Mutex
	rooms map[string]*Room

	roomTTL         time.Duration
	maxJoinAttempts int

	joinAttempts map[string]*rateLimitEntry // keyed by IP
}

// NewRoomManager creates a new RoomManager with default settings.
func NewRoomManager() *RoomManager {
	return &RoomManager{
		rooms:           make(map[string]*Room),
		roomTTL:         10 * time.Minute,
		maxJoinAttempts: 10,
		joinAttempts:    make(map[string]*rateLimitEntry),
	}
}

// Register creates a new room with the given pairing code and daemon sender.
func (rm *RoomManager) Register(code string, daemon Sender) error {
	rm.mu.Lock()
	defer rm.mu.Unlock()

	if _, exists := rm.rooms[code]; exists {
		return ErrRoomExists
	}

	rm.rooms[code] = &Room{
		PairingCode: code,
		Daemon:      daemon,
		LastActive:  time.Now(),
	}
	return nil
}

// Join adds a browser to an existing room. Returns ErrRoomNotFound, ErrRoomLocked, or ErrRateLimited.
func (rm *RoomManager) Join(code string, browser Sender, ip string) error {
	rm.mu.Lock()
	defer rm.mu.Unlock()

	if err := rm.checkRateLimit(ip); err != nil {
		return err
	}

	room, exists := rm.rooms[code]
	if !exists {
		rm.recordAttempt(ip)
		return ErrRoomNotFound
	}

	if room.Locked && room.Browser != nil {
		// Kick the old browser — new connection replaces it
		room.Browser.Send([]byte(`{"type":"peer_replaced"}`))
	}

	room.Browser = browser
	room.Locked = true
	room.LastActive = time.Now()

	// Notify daemon that browser joined
	room.Daemon.Send([]byte(`{"type":"peer_joined"}`))

	return nil
}

// RelayFromBrowser forwards data from the browser to the daemon.
func (rm *RoomManager) RelayFromBrowser(code string, data []byte) error {
	rm.mu.Lock()
	defer rm.mu.Unlock()

	room, exists := rm.rooms[code]
	if !exists {
		return ErrRoomNotFound
	}
	if room.Daemon == nil {
		return ErrNoPeer
	}

	room.LastActive = time.Now()
	return room.Daemon.Send(data)
}

// RelayFromDaemon forwards data from the daemon to the browser.
func (rm *RoomManager) RelayFromDaemon(code string, data []byte) error {
	rm.mu.Lock()
	defer rm.mu.Unlock()

	room, exists := rm.rooms[code]
	if !exists {
		return ErrRoomNotFound
	}
	if room.Browser == nil {
		return ErrNoPeer
	}

	room.LastActive = time.Now()
	return room.Browser.Send(data)
}

// DaemonDisconnected removes the room entirely and notifies the browser.
func (rm *RoomManager) DaemonDisconnected(code string) {
	rm.mu.Lock()
	defer rm.mu.Unlock()

	room, exists := rm.rooms[code]
	if !exists {
		return
	}

	if room.Browser != nil {
		room.Browser.Send([]byte(`{"type":"peer_left"}`))
	}

	delete(rm.rooms, code)
}

// BrowserDisconnected removes the browser from the room and unlocks it.
func (rm *RoomManager) BrowserDisconnected(code string) {
	rm.mu.Lock()
	defer rm.mu.Unlock()

	room, exists := rm.rooms[code]
	if !exists {
		return
	}

	if room.Daemon != nil {
		room.Daemon.Send([]byte(`{"type":"peer_left"}`))
	}

	room.Browser = nil
	room.Locked = false
	room.LastActive = time.Now()
}

// CleanupStale removes rooms that have been inactive longer than roomTTL.
func (rm *RoomManager) CleanupStale() {
	rm.mu.Lock()
	defer rm.mu.Unlock()

	now := time.Now()
	for code, room := range rm.rooms {
		if now.Sub(room.LastActive) > rm.roomTTL {
			if room.Browser != nil {
				room.Browser.Send([]byte(`{"type":"peer_left"}`))
			}
			delete(rm.rooms, code)
		}
	}
}

// checkRateLimit checks if an IP has exceeded join attempts. Must be called with mu held.
func (rm *RoomManager) checkRateLimit(ip string) error {
	entry, exists := rm.joinAttempts[ip]
	if !exists {
		return nil
	}

	// Reset window if more than a minute has passed
	if time.Since(entry.windowAt) > time.Minute {
		delete(rm.joinAttempts, ip)
		return nil
	}

	if entry.count >= rm.maxJoinAttempts {
		return ErrRateLimited
	}
	return nil
}

// recordAttempt increments the join attempt counter for an IP. Must be called with mu held.
func (rm *RoomManager) recordAttempt(ip string) {
	entry, exists := rm.joinAttempts[ip]
	if !exists || time.Since(entry.windowAt) > time.Minute {
		rm.joinAttempts[ip] = &rateLimitEntry{count: 1, windowAt: time.Now()}
		return
	}
	entry.count++
}
