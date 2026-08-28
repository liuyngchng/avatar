package brain

import (
	"log"
	"math"
	"strings"
	"sync"
	"time"

	"github.com/liuyngchng/avatar-desktop/internal/asr"
	"github.com/liuyngchng/avatar-desktop/internal/audio"
	"github.com/liuyngchng/avatar-desktop/internal/kws"
	"github.com/liuyngchng/avatar-desktop/internal/llm"
	"github.com/liuyngchng/avatar-desktop/internal/tts"
)

// Event is a message coming from the renderer (user interaction).
type Event struct {
	Type string `json:"type"`
	Data any    `json:"data,omitempty"`
}

// StateMachine orchestrates the digital human's behavior:
//
//	IDLE (KWS listening) → tap/wake → LISTENING (ASR) → THINKING (LLM) → SPEAKING (TTS) → IDLE
type StateMachine struct {
	state        State
	stateChanges chan State
	outbound     chan any
	events       chan Event

	ttsEngine   *tts.Engine
	audioPlayer *audio.Player
	asrEngine   *asr.Engine
	kwsEngine   *kws.Engine
	llmClient   *llm.Client
	capture     *audio.Capture

	// Conversation history for multi-turn dialogue.
	conversation []llm.Message

	// Audio routing: capture goroutine → audioSink → single consumer goroutine.
	// When idle, audio goes to KWS. When pipeline is active, audio is
	// forwarded to a per-turn buffer channel.
	audioSink <-chan []float32
	asrBuf    chan []float32 // set when pipeline() is listening, then drained

	mu       sync.Mutex
	busy     bool
	done     chan struct{} // closed by Stop() to signal shutdown
	stopOnce sync.Once     // ensures Stop() is idempotent
	wg       sync.WaitGroup // tracks Run() and pipeline() goroutines
}

// NewStateMachine creates a state machine in ModeIdle.
func NewStateMachine(
	ttsEngine *tts.Engine,
	audioPlayer *audio.Player,
	asrEngine *asr.Engine,
	kwsEngine *kws.Engine,
	llmClient *llm.Client,
	capture *audio.Capture,
) *StateMachine {
	sm := &StateMachine{
		state: State{
			Mode:    ModeIdle,
			Emotion: EmotionNeutral,
		},
		stateChanges: make(chan State, 16),
		outbound:     make(chan any, 64),
		events:       make(chan Event, 16),
		ttsEngine:    ttsEngine,
		audioPlayer:  audioPlayer,
		asrEngine:    asrEngine,
		kwsEngine:    kwsEngine,
		llmClient:    llmClient,
		capture:      capture,
		conversation: make([]llm.Message, 0, 20),
		done:         make(chan struct{}),
	}

	// Start audio capture once, shared by KWS and ASR.
	if capture != nil {
		ch, err := capture.Start()
		if err != nil {
			log.Printf("state: audio capture start error: %v", err)
		} else {
			sm.audioSink = ch
		}
	}

	return sm
}

// Run starts the FSM loop. It is the single consumer of audio from the
// capture device. When idle, audio is fed to KWS; when a conversation
// turn is active, audio is forwarded to the pipeline goroutine via asrBuf.
func (sm *StateMachine) Run() {
	sm.wg.Add(1)
	defer sm.wg.Done()

	sm.emit()

	if sm.audioSink == nil {
		log.Println("state: no audio capture, event-only mode")
		for {
			select {
			case ev := <-sm.events:
				sm.handleEvent(ev)
			case <-sm.done:
				return
			}
		}
	}

	log.Println("state: FSM running, audio capture active")

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
		// Close capture to unblock the audio loop.
		if sm.capture != nil {
			sm.capture.Close()
		}
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

		log.Printf("state: event=%s → starting conversation turn", ev.Type)

		// If wake word, say a greeting first.
		if ev.Type == "wake_detected" {
			sm.sayGreeting()
		}

		// Run the conversation turn.
		go sm.pipeline()
	}
}

// sayGreeting speaks a short acknowledgment when woken up.
func (sm *StateMachine) sayGreeting() {
	sm.setState(ModeSpeaking, EmotionHappy, "哎，我在呢")
	sm.mu.Lock()
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

	if err := sm.audioPlayer.PlaySync(result.Samples); err != nil {
		log.Printf("state: greeting playback error: %v", err)
	}

	sm.mu.Lock()
	sm.state.SpeakingText = ""
	sm.mu.Unlock()
}

// pipeline runs a conversation loop: wake word triggers the first turn, then
// each subsequent turn auto-starts until the user stops talking for a while.
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
			log.Println("state: ASR returned empty text, skipping turn")
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

		sm.setState(ModeThinking, emotion, cleanText)
		sm.emit()

		// ── Phase 3: SPEAKING — TTS synthesis + playback ─────────
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
		sm.state.IsSpeaking = true
		sm.state.SpeakingText = cleanText
		sm.mu.Unlock()
		sm.emit()

		if err := sm.audioPlayer.PlaySync(result.Samples); err != nil {
			log.Printf("[TTS] 播放错误: %v", err)
		}
		log.Printf("[TTS] 播放结束, 对话回合%d完成", turn)

		sm.mu.Lock()
		sm.state.IsSpeaking = false
		sm.state.SpeakingText = ""
		sm.mu.Unlock()

		// Loop back to listening for the next turn.
		// collectSpeech() will timeout (no speech) and exit the loop
		// if the user stays silent.
	}
}

// collectSpeech reads from the ASR buffer until silence is detected.
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
		noSpeechTimeout  = 3 * time.Second // exit if no speech within this long
	)

	var allSamples []float32
	silentCount := 0
	speechCount := 0
	deadline := time.After(maxDuration)
	noSpeech := time.NewTimer(noSpeechTimeout)
	defer noSpeech.Stop()

	// returns true if we collected enough real speech to be worth decoding.
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
				noSpeech.Reset(noSpeechTimeout)
			} else {
				silentCount++
			}

			if speechCount >= minSpeechBuffers && silentCount >= silenceHangover {
				return finish("VAD stop")
			}

		case <-noSpeech.C:
			return finish("no speech within 3s")

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