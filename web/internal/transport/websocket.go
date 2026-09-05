// Package transport provides the WebSocket communication layer
// between the browser client and the Go server.
package transport

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/liuyngchng/avatar-web/internal/brain"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool {
		return true // allow all origins (local/air-gapped deployment)
	},
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
}

// WSPacket is the JSON message sent between browser and server.
type WSPacket struct {
	Type string          `json:"type"`
	Data json.RawMessage `json:"data,omitempty"`
}

// Session manages a single WebSocket connection.
type Session struct {
	conn *websocket.Conn
	sm   *brain.StateMachine

	mu      sync.Mutex
	writeCh chan []byte
	closeCh chan struct{}
	closed  bool
}

// NewSession upgrades an HTTP connection to WebSocket and starts
// forwarding messages between the browser and the state machine.
func NewSession(w http.ResponseWriter, r *http.Request, sm *brain.StateMachine) (*Session, error) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return nil, err
	}

	s := &Session{
		conn:    conn,
		sm:      sm,
		writeCh: make(chan []byte, 64),
		closeCh: make(chan struct{}),
	}

	// Write pump: sends messages from the server to the browser.
	go s.writePump()

	// Read pump: receives messages from the browser.
	go s.readPump()

	// Forward state machine outputs to the browser.
	go s.forwardStates()
	go s.forwardOutbound()
	go s.forwardAudio()

	slog.Info("websocket_session_started")
	return s, nil
}

// readPump reads messages from the browser.
func (s *Session) readPump() {
	defer func() {
		s.Close()
	}()

	s.conn.SetReadLimit(65536)
	s.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	s.conn.SetPongHandler(func(string) error {
		s.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		return nil
	})

	for {
		_, message, err := s.conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
				slog.Warn("websocket_read_error", "error", err)
			}
			return
		}

		var pkt WSPacket
		if err := json.Unmarshal(message, &pkt); err != nil {
			slog.Warn("websocket_bad_json_from_browser", "error", err)
			continue
		}

		s.handlePacket(pkt)
	}
}

// handlePacket dispatches incoming browser messages.
func (s *Session) handlePacket(pkt WSPacket) {
	switch pkt.Type {
	case "audio":
		// Browser sent microphone audio (PCM float32 array).
		var samples []float32
		if err := json.Unmarshal(pkt.Data, &samples); err != nil {
			slog.Warn("websocket_bad_audio_data", "error", err)
			return
		}
		s.sm.FeedAudio(samples)

	case "tap":
		s.sm.HandleEvent(brain.Event{Type: "tap"})

	case "ping":
		s.writeJSON(WSPacket{Type: "pong"})

	default:
		slog.Warn("websocket_unknown_packet_type", "type", pkt.Type)
	}
}

// forwardStates pushes state machine mode/emotion changes to the browser.
func (s *Session) forwardStates() {
	for state := range s.sm.StateChanges() {
		s.writeJSON(state)
	}
}

// forwardOutbound pushes viseme timelines and other messages to the browser.
func (s *Session) forwardOutbound() {
	for msg := range s.sm.Outbound() {
		s.writeJSON(msg)
	}
}

// forwardAudio pushes TTS audio samples to the browser.
func (s *Session) forwardAudio() {
	for audio := range s.sm.AudioOut() {
		s.writeJSON(audio)
	}
}

// writeJSON marshals and enqueues a message to the browser.
func (s *Session) writeJSON(v any) {
	data, err := json.Marshal(v)
	if err != nil {
		slog.Warn("websocket_marshal_error", "error", err)
		return
	}

	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.mu.Unlock()

	select {
	case s.writeCh <- data:
	default:
		slog.Warn("websocket_write_buffer_full_dropping")
	}
}

// writePump sends enqueued messages to the browser.
func (s *Session) writePump() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case data, ok := <-s.writeCh:
			if !ok {
				return
			}
			s.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := s.conn.WriteMessage(websocket.TextMessage, data); err != nil {
				slog.Warn("websocket_write_error", "error", err)
				return
			}

		case <-ticker.C:
			s.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := s.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				slog.Warn("websocket_ping_error", "error", err)
				return
			}

		case <-s.closeCh:
			return
		}
	}
}

// Close terminates the WebSocket session.
func (s *Session) Close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	s.mu.Unlock()

	close(s.closeCh)
	close(s.writeCh)
	s.conn.Close()
	slog.Info("websocket_session_closed")
}
