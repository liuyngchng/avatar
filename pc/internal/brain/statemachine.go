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
//
// P1 scope: uses real TTS + audio playback instead of the P0 demo timer loop.
// ASR and LLM are still simulated — the canned text is synthesized via
// sherpa-onnx Matcha-TTS and played through oto/ALSA. Viseme timeline drives
// lip-sync.
type StateMachine struct {
	state        State
	stateChanges chan State
	events       chan Event
	visemes      chan VisemeEvent
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
		events:       make(chan Event, 16),
		visemes:      make(chan VisemeEvent, 64),
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

// Visemes returns the channel of viseme events the main loop forwards
// to the renderer for lip-sync.
func (sm *StateMachine) Visemes() <-chan VisemeEvent {
	return sm.visemes
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

	// Generate viseme timeline.
	audioDur := time.Duration(float64(len(result.Samples)) / float64(result.SampleRate) * float64(time.Second))
	timeline := GenerateVisemeTimeline(text, audioDur)
	log.Printf("state: viseme timeline: %d entries, total audio %.1fs", len(timeline), audioDur.Seconds())

	// Speaking.
	sm.mu.Lock()
	sm.state.Mode = ModeSpeaking
	sm.state.IsSpeaking = true
	sm.mu.Unlock()
	sm.emit()

	// Play audio (non-blocking).
	player, err := sm.audioPlayer.Play(result.Samples)
	if err != nil {
		log.Printf("state: audio play error: %v", err)
		sm.mu.Lock()
		sm.state.IsSpeaking = false
		sm.mu.Unlock()
		sm.setState(ModeIdle, EmotionNeutral, "")
		sm.emit()
		return
	}

	// Drive viseme timeline while audio plays.
	startTime := time.Now()
	timelineIdx := 0
	for player.IsPlaying() {
		if err := player.Err(); err != nil {
			log.Printf("state: audio play error: %v", err)
			break
		}

		elapsed := time.Since(startTime).Milliseconds()

		// Emit any viseme entries whose start time has been reached.
		for timelineIdx < len(timeline) && int64(timeline[timelineIdx].StartMs) <= elapsed {
			entry := timeline[timelineIdx]
			ev := VisemeEvent{
				Type:   "viseme",
				Viseme: entry.Viseme,
				Weight: 1.0,
			}
			select {
			case sm.visemes <- ev:
			default:
			}
			timelineIdx++
		}

		time.Sleep(10 * time.Millisecond)
	}

	// Reset viseme to rest.
	select {
	case sm.visemes <- VisemeEvent{Type: "viseme", Viseme: VisemeRest, Weight: 0}:
	default:
	}

	// Back to idle.
	sm.mu.Lock()
	sm.state.IsSpeaking = false
	sm.mu.Unlock()
	sm.setState(ModeIdle, EmotionNeutral, "")
	sm.emit()
}
