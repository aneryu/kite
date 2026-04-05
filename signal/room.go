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
		tm.recordAttempt(ip)
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
	if entry.count > tm.maxJoinAttempts {
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
