package brain

import (
	"log"
	"sync"
	"time"

	"github.com/liuyngchng/avatar-pc/internal/audio"
	"github.com/liuyngchng/avatar-pc/internal/tts"
)

// Event is a message coming from the renderer (user interaction).
// It's intentionally opaque for now; typed events get added in P2.
type Event struct {
	Type string `json:"type"`
	Data any    `json:"data,omitempty"`
}

// StateMachine orchestrates the digital human's behavior.
type StateMachine struct {
	state        State
	stateChanges chan State
	outbound     chan any
	events       chan Event
	ttsEngine    *tts.Engine
	audioPlayer  *audio.Player

	mu   sync.Mutex
	busy bool
}

// NewStateMachine creates a state machine in ModeIdle.
func NewStateMachine(ttsEngine *tts.Engine, audioPlayer *audio.Player) *StateMachine {
	return &StateMachine{
		state: State{
			Mode:    ModeIdle,
			Emotion: EmotionNeutral,
		},
		stateChanges: make(chan State, 16),
		outbound:     make(chan any, 64),
		events:       make(chan Event, 16),
		ttsEngine:    ttsEngine,
		audioPlayer:  audioPlayer,
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

// Outbound returns the channel of arbitrary messages (viseme timelines, etc.)
// the main loop forwards to the renderer.
func (sm *StateMachine) Outbound() <-chan any {
	return sm.outbound
}

// HandleEvent feeds a renderer event into the FSM.
func (sm *StateMachine) HandleEvent(ev Event) {
	sm.events <- ev
}

func (sm *StateMachine) emit() {
	sm.mu.Lock()
	s := sm.state // copy
	sm.mu.Unlock()
	select {
	case sm.stateChanges <- s:
	default:
	}
}

func (sm *StateMachine) handleEvent(ev Event) {
	switch ev.Type {
	case "tap", "wake_detected":
		sm.mu.Lock()
		if sm.busy {
			sm.mu.Unlock()
			log.Printf("state: event=%s ignored (busy)", ev.Type)
			return
		}
		sm.busy = true
		sm.mu.Unlock()

		log.Printf("state: event=%s → listening", ev.Type)
		sm.setState(ModeListening, EmotionNeutral, "")
		sm.emit()

		// P1: simulate the ASR→LLM pipeline with real TTS output.
		go sm.pipeline()
	}
}

// setState safely updates the state fields.
func (sm *StateMachine) setState(mode Mode, emotion Emotion, responseText string) {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	sm.state.Mode = mode
	sm.state.Emotion = emotion
	if responseText != "" {
		sm.state.ResponseText = responseText
	}
}

// pipeline runs a conversation turn: thinking → TTS synthesis → speaking.
// ASR and LLM are still fake (canned text), but the TTS, audio playback, and
// viseme lip-sync are real. Replaced by full ASR→LLM→TTS in P1c/P1d.
func (sm *StateMachine) pipeline() {
	// Clear the busy flag when this turn completes.
	defer func() {
		sm.mu.Lock()
		sm.busy = false
		sm.mu.Unlock()
	}()

	// Thinking.
	sm.setState(ModeThinking, EmotionNeutral, "")
	sm.emit()
	time.Sleep(800 * time.Millisecond)

	// Synthesize with real TTS.
	text := "你好，我是企业数字人。"
	sm.setState(ModeThinking, EmotionHappy, text)

	result, err := sm.ttsEngine.Synthesize(text, 1.0)
	if err != nil {
		log.Printf("state: TTS synthesis failed: %v", err)
		sm.setState(ModeIdle, EmotionNeutral, "")
		sm.emit()
		return
	}

	// Generate viseme timeline and send it to the frontend once.
	audioDurMs := int(float64(len(result.Samples)) / float64(result.SampleRate) * 1000)
	timeline := GenerateVisemeTimeline(text, audioDurMs)
	if timeline != nil {
		log.Printf("state: viseme timeline: %d entries, audio %dms", len(timeline.Timeline), audioDurMs)
		select {
		case sm.outbound <- timeline:
		default:
		}
	}

	// Speaking.
	sm.mu.Lock()
	sm.state.Mode = ModeSpeaking
	sm.state.IsSpeaking = true
	sm.mu.Unlock()
	sm.emit()

	// Play audio (blocking).
	if err := sm.audioPlayer.PlaySync(result.Samples); err != nil {
		log.Printf("state: audio playback error: %v", err)
	}

	// Back to idle.
	sm.mu.Lock()
	sm.state.IsSpeaking = false
	sm.mu.Unlock()
	sm.setState(ModeIdle, EmotionNeutral, "")
	sm.emit()
}
