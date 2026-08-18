package brain

import (
	"log"
	"time"
)

// Event is a message coming from the renderer (user interaction).
// It's intentionally opaque for now; typed events get added in P2.
type Event struct {
	Type string `json:"type"`
	Data any    `json:"data,omitempty"`
}

// StateMachine orchestrates the digital human's behavior.
//
// P0 scope: a minimal FSM that just advances idle → listening → thinking →
// speaking → idle, so the renderer has something to react to. ASR/TTS/LLM
// get wired in during P1/P2.
type StateMachine struct {
	state        State
	stateChanges chan State
	events       chan Event
}

// NewStateMachine creates a state machine in ModeIdle.
func NewStateMachine() *StateMachine {
	return &StateMachine{
		state: State{
			Mode:    ModeIdle,
			Emotion: EmotionNeutral,
		},
		stateChanges: make(chan State, 16),
		events:       make(chan Event, 16),
	}
}

// Run starts the FSM loop. It blocks until the channel is closed.
func (sm *StateMachine) Run() {
	sm.emit()
	for ev := range sm.events {
		sm.handleEvent(ev)
	}
}

// StateChanges returns the channel of state updates the main loop
// forwards to the renderer.
func (sm *StateMachine) StateChanges() <-chan State {
	return sm.stateChanges
}

// HandleEvent feeds a renderer event into the FSM.
func (sm *StateMachine) HandleEvent(ev Event) {
	sm.events <- ev
}

func (sm *StateMachine) emit() {
	select {
	case sm.stateChanges <- sm.state:
	default:
	}
}

func (sm *StateMachine) handleEvent(ev Event) {
	switch ev.Type {
	case "tap", "wake_detected":
		log.Printf("state: event=%s → listening", ev.Type)
		sm.state.Mode = ModeListening
		sm.emit()

		// P0 demo: simulate the ASR→LLM→TTS pipeline with timers so the
		// renderer can visually react. Replaced by real engines in P1/P2.
		go sm.demoPipeline()
	}
}

// demoPipeline simulates a full conversation turn. It will be replaced by
// the real ASR → LLM → TTS chain. Present only so P0 can show all four
// states and a talking avatar without the native engines.
func (sm *StateMachine) demoPipeline() {
	// Thinking.
	sm.state.Mode = ModeThinking
	sm.state.Emotion = EmotionNeutral
	sm.emit()
	time.Sleep(1200 * time.Millisecond)

	// Speaking with a canned reply.
	sm.state.Mode = ModeSpeaking
	sm.state.Emotion = EmotionHappy
	sm.state.ResponseText = "你好，我是企业数字人。"
	sm.state.IsSpeaking = true
	sm.emit()
	time.Sleep(2200 * time.Millisecond)

	// Back to idle.
	sm.state.IsSpeaking = false
	sm.state.Mode = ModeIdle
	sm.state.Emotion = EmotionNeutral
	sm.emit()
}
