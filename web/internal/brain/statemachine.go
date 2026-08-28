// Package brain contains the state machine and the digital human's
// "mind": mode FSM, emotion mapping, and viseme generation.
//
// This is the web-specific version. Audio I/O is handled in the browser
// and communicated over WebSocket; the server only runs the inference
// pipeline (KWS → ASR → LLM → TTS).
package brain

import (
	"fmt"
	"log"
	"math"
	"strings"
	"sync"
	"time"

	"github.com/liuyngchng/avatar-web/internal/asr"
	"github.com/liuyngchng/avatar-web/internal/kws"
	"github.com/liuyngchng/avatar-web/internal/llm"
	"github.com/liuyngchng/avatar-web/internal/tts"
)

// Event is a message coming from the renderer (user interaction).
type Event struct {
	Type string `json:"type"`
	Data any    `json:"data,omitempty"`
}

// AudioPacket carries PCM audio samples from the browser to the server,
// or from the server to the browser.
type AudioPacket struct {
	Samples    []float32 `json:"samples"`
	SampleRate int       `json:"sampleRate"`
}

// StateMachine orchestrates the digital human's behavior.
// Audio capture and playback happen in the browser; the server handles
// wake-word detection, ASR, LLM, and TTS inference.
//
// The FSM is multi-turn: after wake or tap, it loops LISTENING → THINKING
// → SPEAKING → LISTENING until the user stays silent past
// Config.NoSpeechTimeout.
type StateMachine struct {
	state        State
	stateChanges chan State
	outbound     chan any // viseme timeline, state updates → browser
	audioOut     chan AudioPacket // TTS audio → browser
	events       chan Event

	ttsEngine *tts.Engine
	asrEngine *asr.Engine
	kwsEngine *kws.Engine
	llmClient *llm.Client

	// noSpeechTimeout ends the multi-turn conversation if the user produces
	// no speech within this duration. Sourced from Config.NoSpeechTimeout
	// (default: DefaultNoSpeechTimeout = 5s).
	noSpeechTimeout time.Duration

	// Conversation history for multi-turn dialogue.
	conversation []llm.Message

	// Audio routing: WebSocket goroutine → audioSink → FSM loop.
	// When idle, audio goes to KWS. When pipeline is active, audio is
	// forwarded to a per-turn buffer channel.
	audioSink chan []float32
	asrBuf    chan []float32 // set when pipeline() is listening, then drained

	mu       sync.Mutex
	busy     bool
	done     chan struct{} // closed by Stop() to signal shutdown
	stopOnce sync.Once     // ensures Stop() is idempotent
	wg       sync.WaitGroup // tracks Run() and pipeline() goroutines
}

// DefaultNoSpeechTimeout is used when Config.NoSpeechTimeout is zero or
// not provided. After this much silence (no RMS above silenceThreshold),
// the multi-turn conversation is closed and the user must wake the avatar
// again to talk.
const DefaultNoSpeechTimeout = 5 * time.Second

// Config tunes conversation-level timing on the state machine. Zero or
// negative values fall back to the package-level defaults.
type Config struct {
	// NoSpeechTimeout ends a multi-turn conversation if the user produces
	// no speech within this duration after wake-up or after the previous
	// turn ends. Zero or negative falls back to DefaultNoSpeechTimeout (5s).
	NoSpeechTimeout time.Duration
}

// NewStateMachine creates a state machine in ModeIdle.
func NewStateMachine(
	ttsEngine *tts.Engine,
	asrEngine *asr.Engine,
	kwsEngine *kws.Engine,
	llmClient *llm.Client,
	cfg Config,
) *StateMachine {
	if cfg.NoSpeechTimeout <= 0 {
		cfg.NoSpeechTimeout = DefaultNoSpeechTimeout
	}
	sm := &StateMachine{
		state: State{
			Mode:    ModeIdle,
			Emotion: EmotionNeutral,
		},
		stateChanges:    make(chan State, 16),
		outbound:        make(chan any, 64),
		audioOut:        make(chan AudioPacket, 8),
		events:          make(chan Event, 16),
		audioSink:       make(chan []float32, 128),
		ttsEngine:       ttsEngine,
		asrEngine:       asrEngine,
		kwsEngine:       kwsEngine,
		llmClient:       llmClient,
		noSpeechTimeout: cfg.NoSpeechTimeout,
		conversation:    make([]llm.Message, 0, 20),
		done:            make(chan struct{}),
	}

	return sm
}

// FeedAudio pushes audio samples from the WebSocket into the FSM.
// Called by the transport layer when the browser sends microphone data.
func (sm *StateMachine) FeedAudio(samples []float32) {
	select {
	case sm.audioSink <- samples:
	default:
		// Buffer full, drop oldest.
	}
}

// Run starts the FSM loop. It is the single consumer of audio from the
// browser. When idle, audio is fed to KWS; when a conversation turn is
// active, audio is forwarded to the pipeline goroutine via asrBuf.
func (sm *StateMachine) Run() {
	sm.wg.Add(1)
	defer sm.wg.Done()

	sm.emit()
	log.Println("state: FSM running, waiting for audio from browser")

	for {
		select {
		case ev := <-sm.events:
			sm.handleEvent(ev)

		case samples, ok := <-sm.audioSink:
			if !ok {
				log.Println("state: audio channel closed, FSM exiting")
				return
			}

			sm.mu.Lock()
			curBusy := sm.busy
			asrBuf := sm.asrBuf
			sm.mu.Unlock()

			if curBusy && asrBuf != nil {
				// Pipeline is listening — forward to ASR buffer.
				select {
				case asrBuf <- samples:
				default:
					// Buffer full, drop oldest.
				}
			} else {
				// Idle: feed KWS for wake word detection.
				if sm.kwsEngine != nil {
					keyword := sm.kwsEngine.ProcessSamples(samples)
					if keyword != "" {
						log.Printf("state: KWS detected keyword=%q", keyword)
						sm.HandleEvent(Event{Type: "wake_detected"})
					}
				}
			}

		case <-sm.done:
			log.Println("state: FSM shutdown signal, exiting")
			return
		}
	}
}

// Stop signals the state machine to stop and waits for all goroutines to exit.
// Must be called before the engine closes (KWS/ASR/TTS) to avoid use-after-free
// crashes on the CGo-backed engines.
func (sm *StateMachine) Stop() {
	sm.stopOnce.Do(func() {
		close(sm.done)
	})
	sm.wg.Wait()
}

// StateChanges returns the channel of state updates.
func (sm *StateMachine) StateChanges() <-chan State {
	return sm.stateChanges
}

// Outbound returns the channel of viseme timelines, etc.
func (sm *StateMachine) Outbound() <-chan any {
	return sm.outbound
}

// AudioOut returns the channel of TTS audio packets to send to the browser.
func (sm *StateMachine) AudioOut() <-chan AudioPacket {
	return sm.audioOut
}

// HandleEvent feeds a renderer event into the FSM.
func (sm *StateMachine) HandleEvent(ev Event) {
	select {
	case sm.events <- ev:
	default:
		log.Printf("state: dropping event (channel full): %s", ev.Type)
	}
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

		log.Printf("state: event=%s → starting conversation turn", ev.Type)

		// Kick off the conversation turn in a separate goroutine so that
		// the FSM Run() loop is never blocked.  For wake-word triggers we
		// say a greeting first, then start the pipeline; for tap we jump
		// straight into listening.
		go func() {
			if ev.Type == "wake_detected" {
				sm.sayGreeting()
			}
			sm.pipeline()
		}()
	}
}

// sayGreeting speaks a short acknowledgment when woken up.
func (sm *StateMachine) sayGreeting() {
	sm.mu.Lock()
	sm.state.Mode = ModeSpeaking
	sm.state.Emotion = EmotionHappy
	sm.state.SpeakingText = "哎，我在呢"
	sm.mu.Unlock()
	sm.emit()

	result, err := sm.ttsEngine.Synthesize("哎，我在呢", 1.0)
	if err != nil {
		log.Printf("state: greeting TTS error: %v", err)
		return
	}

	audioDurMs := int(float64(len(result.Samples)) / float64(result.SampleRate) * 1000)
	timeline := GenerateVisemeTimeline("哎，我在呢", audioDurMs)
	if timeline != nil {
		select {
		case sm.outbound <- timeline:
		default:
		}
	}

	// Send audio to browser for playback.
	sm.sendAudioOut(result)

	sm.mu.Lock()
	sm.state.SpeakingText = ""
	sm.mu.Unlock()
}

// pipeline runs a multi-turn conversation loop: wake word triggers the
// first turn, then each subsequent turn auto-starts until the user stops
// talking for longer than noSpeechTimeout.
//
//	LISTENING → ASR → THINKING → LLM → TTS → SPEAKING → (loop) → IDLE
func (sm *StateMachine) pipeline() {
	sm.wg.Add(1)
	defer sm.wg.Done()

	defer func() {
		sm.mu.Lock()
		sm.busy = false
		sm.mu.Unlock()
	}()

	// Multi-turn loop: keep listening after each turn until the user
	// stays silent, then fall back to idle (wake-word required again).
	for turn := 1; ; turn++ {
		// ── Phase 1: LISTENING — capture audio for ASR ──────────
		log.Printf("[ASR] 开始聆听... (第%d轮)", turn)
		sm.setState(ModeListening, EmotionNeutral, "")
		sm.mu.Lock()
		sm.state.IsSpeaking = false
		sm.state.SpeakingText = ""
		sm.mu.Unlock()
		sm.emit()

		// Create ASR buffer. Run() will forward audio here.
		sm.mu.Lock()
		sm.asrBuf = make(chan []float32, 64)
		sm.mu.Unlock()

		audioSamples := sm.collectSpeech()

		// Close ASR buffer.
		sm.mu.Lock()
		close(sm.asrBuf)
		sm.asrBuf = nil
		sm.mu.Unlock()

		if len(audioSamples) == 0 {
			log.Println("state: no speech detected, ending conversation")
			sm.setState(ModeIdle, EmotionNeutral, "")
			sm.emit()
			return
		}

		// ── Phase 2: THINKING — ASR then LLM ─────────────────────
		sm.setState(ModeThinking, EmotionNeutral, "")
		sm.emit()

		userText := "你好"
		if sm.asrEngine != nil {
			result, err := sm.asrEngine.Decode(audioSamples)
			if err != nil {
				log.Printf("state: ASR error: %v", err)
				sm.setState(ModeIdle, EmotionNeutral, "")
				sm.emit()
				return
			}
			userText = strings.TrimSpace(result.Text)
			log.Printf("[ASR] 结束: result=%q, lang=%s, emotion=%s", userText, result.Lang, result.Emotion)
		}

		if userText == "" {
			log.Println("state: ASR returned empty text, ending conversation")
			sm.setState(ModeIdle, EmotionNeutral, "")
			sm.emit()
			return
		}

		sm.mu.Lock()
		sm.state.LastUserText = userText
		sm.mu.Unlock()

		// Call LLM.
		log.Printf("[LLM] 请求开始: user=%q", userText)
		llmStart := time.Now()
		llmText := sm.callLLM(userText)
		log.Printf("[LLM] 请求结束: 耗时=%v, chars=%d", time.Since(llmStart).Round(time.Millisecond), len(llmText))
		if llmText == "" {
			llmText = "你好，我是企业数字人，请问有什么可以帮你的？"
		}

		emotionStr, cleanText := llm.ParseEmotion(llmText)
		emotion := EmotionFromString(emotionStr)

		// ── Phase 3: SPEAKING — TTS synthesis ────────────────────
		log.Printf("[TTS] 合成开始: text=%q", cleanText)
		ttsStart := time.Now()
		result, err := sm.ttsEngine.Synthesize(cleanText, 1.0)
		if err != nil {
			log.Printf("[TTS] 合成失败: %v", err)
			sm.setState(ModeIdle, EmotionNeutral, "")
			sm.emit()
			return
		}

		audioDurMs := int(float64(len(result.Samples)) / float64(result.SampleRate) * 1000)
		log.Printf("[TTS] 合成结束: 耗时=%v, 音频=%dms, samples=%d",
			time.Since(ttsStart).Round(time.Millisecond), audioDurMs, len(result.Samples))
		timeline := GenerateVisemeTimeline(cleanText, audioDurMs)
		if timeline != nil {
			log.Printf("state: viseme timeline: %d entries, audio %dms", len(timeline.Timeline), audioDurMs)
			select {
			case sm.outbound <- timeline:
			default:
			}
		}

		sm.mu.Lock()
		sm.state.Mode = ModeSpeaking
		sm.state.Emotion = emotion
		sm.state.IsSpeaking = true
		sm.state.SpeakingText = cleanText
		sm.mu.Unlock()
		sm.emit()

		// Send audio to browser for playback.
		sm.sendAudioOut(result)

		log.Printf("[TTS] 播放结束, 对话回合%d完成", turn)

		sm.mu.Lock()
		sm.state.IsSpeaking = false
		sm.state.SpeakingText = ""
		sm.mu.Unlock()
		sm.emit()

		// Loop back to listening for the next turn.
		// collectSpeech() will timeout (no speech) and exit the loop
		// if the user stays silent.
	}
}

// sendAudioOut sends TTS audio to the browser via the audioOut channel.
func (sm *StateMachine) sendAudioOut(result *tts.SynthesizeResult) {
	select {
	case sm.audioOut <- AudioPacket{
		Samples:    result.Samples,
		SampleRate: result.SampleRate,
	}:
	default:
		log.Printf("state: audioOut channel full, dropping audio")
	}
}

// collectSpeech reads from the ASR buffer until silence is detected or
// noSpeechTimeout passes without any speech.
func (sm *StateMachine) collectSpeech() []float32 {
	sm.mu.Lock()
	asrBuf := sm.asrBuf
	sm.mu.Unlock()

	if asrBuf == nil {
		return nil
	}

	const (
		silenceThreshold = 0.02 // RMS below this is treated as silence; raise if ambient noise trips VAD
		silenceHangover  = 15   // 15 × 100ms = 1.5s of trailing silence after speech
		maxDuration      = 15 * time.Second
		minSpeechBuffers = 5
	)

	var allSamples []float32
	silentCount := 0
	speechCount := 0
	deadline := time.After(maxDuration)
	noSpeech := time.NewTimer(sm.noSpeechTimeout)
	defer noSpeech.Stop()

	// returns nil if we didn't collect enough real speech to be worth decoding.
	finish := func(why string) []float32 {
		log.Printf("state: %s — speech=%d buffers, silence=%d, total=%d samples",
			why, speechCount, silentCount, len(allSamples))
		if speechCount < minSpeechBuffers {
			log.Printf("state: %s → too little speech, treating as silence", why)
			return nil
		}
		return allSamples
	}

	for {
		select {
		case samples, ok := <-asrBuf:
			if !ok {
				return finish("buffer closed")
			}

			allSamples = append(allSamples, samples...)

			rms := computeRMS(samples)
			if rms > silenceThreshold {
				silentCount = 0
				speechCount++
				// Reset the no-speech timer: user is (possibly) speaking.
				if !noSpeech.Stop() {
					select {
					case <-noSpeech.C:
					default:
					}
				}
				noSpeech.Reset(sm.noSpeechTimeout)
			} else {
				silentCount++
			}

			if speechCount >= minSpeechBuffers && silentCount >= silenceHangover {
				return finish("VAD stop")
			}

		case <-noSpeech.C:
			return finish(fmt.Sprintf("no speech within %s", sm.noSpeechTimeout))

		case <-deadline:
			return finish("VAD timeout")

		case <-sm.done:
			return finish("shutdown")
		}
	}
}

// callLLM sends the user text to the LLM and returns the full response.
func (sm *StateMachine) callLLM(userText string) string {
	if sm.llmClient == nil || !sm.llmClient.IsConfigured() {
		log.Println("state: LLM not configured, using fallback")
		return ""
	}

	sm.mu.Lock()
	sm.conversation = append(sm.conversation, llm.Message{
		Role: "user", Content: userText,
	})
	// Keep at most 10 complete rounds (20 messages). Drop oldest
	// user+assistant pair when the limit is exceeded so the history
	// always starts with a "user" message.
	if len(sm.conversation) > 20 {
		sm.conversation = sm.conversation[2:]
	}
	sm.mu.Unlock()

	chunkCh, errCh := sm.llmClient.ChatStream(sm.conversation, llm.DefaultParams())

	var fullText strings.Builder
	done := false

	for !done {
		select {
		case chunk, ok := <-chunkCh:
			if !ok {
				done = true
			} else {
				fullText.WriteString(chunk)
			}
		case err := <-errCh:
			if err != nil {
				log.Printf("state: LLM error: %v", err)
				return ""
			}
		case <-sm.done:
			log.Println("state: LLM cancelled by shutdown")
			return ""
		}
	}

	response := fullText.String()
	log.Printf("state: LLM response (%d chars): %s", len(response), truncate(response, 100))

	if response != "" {
		_, cleanText := llm.ParseEmotion(response)
		sm.mu.Lock()
		sm.conversation = append(sm.conversation, llm.Message{
			Role: "assistant", Content: cleanText,
		})
		if len(sm.conversation) > 20 {
			sm.conversation = sm.conversation[2:]
		}
		sm.mu.Unlock()
	}

	return response
}

func computeRMS(samples []float32) float64 {
	if len(samples) == 0 {
		return 0
	}
	var sum float64
	for _, s := range samples {
		sum += float64(s) * float64(s)
	}
	return math.Sqrt(sum / float64(len(samples)))
}

func truncate(s string, maxLen int) string {
	runes := []rune(s)
	if len(runes) <= maxLen {
		return s
	}
	return string(runes[:maxLen]) + "..."
}

func (sm *StateMachine) setState(mode Mode, emotion Emotion, responseText string) {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	sm.state.Mode = mode
	sm.state.Emotion = emotion
}

// EmotionFromString converts a string to an Emotion enum.
func EmotionFromString(s string) Emotion {
	switch strings.ToLower(s) {
	case "happy":
		return EmotionHappy
	case "angry":
		return EmotionAngry
	case "surprised":
		return EmotionSurprised
	case "relaxed":
		return EmotionRelaxed
	case "sad":
		return EmotionSad
	default:
		return EmotionNeutral
	}
}

// ClearConversation resets the conversation history.
func (sm *StateMachine) ClearConversation() {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	sm.conversation = sm.conversation[:0]
}
