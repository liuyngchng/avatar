// Package tts wraps the speech synthesis engine.
// Supports both offline (sherpa-onnx Matcha-TTS + vocos) and online
// (DashScope Qwen-TTS Realtime WebSocket) modes.
package tts

import (
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	sherpa "github.com/k2-fsa/sherpa-onnx-go/sherpa_onnx"
)

// Mode is the TTS engine mode.
type Mode string

const (
	ModeOffline Mode = "offline"
	ModeOnline  Mode = "online"
)

// ModelPaths holds the required model file paths for offline TTS.
type ModelPaths struct {
	AcousticModel string // model.onnx (Matcha acoustic model)
	Vocoder       string // vocos.onnx
	Tokens        string // tokens.txt
	Lexicon       string // lexicon.txt
}

// Engine wraps a TTS engine (offline or online).
type Engine struct {
	mode       Mode
	tts        *sherpa.OfflineTts // offline only
	sampleRate int

	// Online TTS config (DashScope Qwen-TTS Realtime WebSocket).
	onlineURL        string
	onlineModel      string
	onlineVoice      string
	onlineAPIKey     string
	onlineFormat     string
	onlineSampleRate int

	// Online WebSocket connection (lazy, reused).
	mu     sync.Mutex
	conn   *websocket.Conn
	reqMu  sync.Mutex
	dialer *websocket.Dialer
}

// SynthesizeResult contains the result of a TTS synthesis.
type SynthesizeResult struct {
	Samples    []float32 // normalized float32 PCM samples in [-1, 1]
	SampleRate int       // sample rate in Hz
	Duration   float64   // audio duration in seconds
}

// New creates a new TTS engine.
// If mode is "online", p is ignored and the online API is used.
// If mode is "offline", p must contain valid model paths.
// proxyFunc is the http.Proxy function used for the WebSocket connection
// in online mode.
func New(mode Mode, p ModelPaths, onlineURL, onlineModel, onlineVoice, onlineAPIKey string, onlineFormat string, onlineSampleRate int, proxyFunc func(*http.Request) (*url.URL, error)) (*Engine, error) {
	e := &Engine{
		mode:             mode,
		onlineURL:        onlineURL,
		onlineModel:      onlineModel,
		onlineVoice:      onlineVoice,
		onlineAPIKey:     onlineAPIKey,
		onlineFormat:     onlineFormat,
		onlineSampleRate: onlineSampleRate,
		dialer: &websocket.Dialer{
			Proxy:            proxyFunc,
			HandshakeTimeout: 30 * time.Second,
		},
	}

	if mode == ModeOnline {
		if onlineURL == "" || onlineAPIKey == "" {
			return nil, fmt.Errorf("tts: online mode requires url and api_key")
		}
		if onlineFormat == "" {
			e.onlineFormat = "pcm"
		}
		if onlineSampleRate <= 0 {
			e.onlineSampleRate = 24000
		}
		e.sampleRate = e.onlineSampleRate
		log.Printf("tts: using online engine (DashScope Qwen-TTS), model=%s, voice=%s", onlineModel, onlineVoice)
		return e, nil
	}

	// Offline mode: initialize sherpa-onnx.
	for _, f := range []string{p.AcousticModel, p.Vocoder, p.Tokens, p.Lexicon} {
		if _, err := os.Stat(f); err != nil {
			return nil, fmt.Errorf("tts: model file not found: %s", f)
		}
	}

	numThreads := runtime.NumCPU()
	if numThreads > 4 {
		numThreads = 4
	}
	if numThreads < 2 {
		numThreads = 2
	}

	config := &sherpa.OfflineTtsConfig{
		Model: sherpa.OfflineTtsModelConfig{
			Matcha: sherpa.OfflineTtsMatchaModelConfig{
				AcousticModel: p.AcousticModel,
				Vocoder:       p.Vocoder,
				Tokens:        p.Tokens,
				Lexicon:       p.Lexicon,
				NoiseScale:    0.667,
				LengthScale:   1.0,
			},
			NumThreads: numThreads,
			Provider:   "cpu",
			Debug:      0,
		},
		MaxNumSentences: 1,
		SilenceScale:    0.2,
	}

	tts := sherpa.NewOfflineTts(config)
	if tts == nil {
		return nil, fmt.Errorf("tts: failed to create engine (check model paths)")
	}

	e.tts = tts
	e.sampleRate = tts.SampleRate()
	log.Printf("tts: offline engine created, sample_rate=%d, num_threads=%d", e.sampleRate, numThreads)
	return e, nil
}

// Synthesize converts text to speech.
func (e *Engine) Synthesize(text string, speed float32) (*SynthesizeResult, error) {
	if e.mode == ModeOnline {
		return e.synthesizeOnline(text, speed)
	}
	return e.synthesizeOffline(text, speed)
}

func (e *Engine) synthesizeOffline(text string, speed float32) (*SynthesizeResult, error) {
	if e.tts == nil {
		return nil, fmt.Errorf("tts: offline engine not initialized")
	}
	if speed <= 0 {
		speed = 1.0
	}

	audio := e.tts.Generate(text, 0 /* sid */, speed)
	if audio == nil {
		return nil, fmt.Errorf("tts: synthesis produced no audio")
	}

	dur := float64(len(audio.Samples)) / float64(audio.SampleRate)
	log.Printf("tts: offline synthesized %d samples (%.1fs) for %d chars",
		len(audio.Samples), dur, len([]rune(text)))

	return &SynthesizeResult{
		Samples:    audio.Samples,
		SampleRate: audio.SampleRate,
		Duration:   dur,
	}, nil
}

// synthesizeOnline sends text to the DashScope Qwen-TTS Realtime WebSocket API.
func (e *Engine) synthesizeOnline(text string, speed float32) (*SynthesizeResult, error) {
	_ = speed // speed not supported by Qwen-TTS realtime API

	e.reqMu.Lock()
	defer e.reqMu.Unlock()

	t0 := time.Now()

	e.mu.Lock()
	if err := e.ensureConnectedLocked(); err != nil {
		e.mu.Unlock()
		return nil, err
	}

	// Send the text.
	appendEvent := map[string]interface{}{
		"event_id": fmt.Sprintf("event_%d", time.Now().UnixNano()),
		"type":     "input_text_buffer.append",
		"text":     text,
	}
	if err := e.conn.WriteJSON(appendEvent); err != nil {
		log.Printf("tts: write append failed, reconnecting: %v", err)
		e.closeLocked()
		if err2 := e.ensureConnectedLocked(); err2 != nil {
			e.mu.Unlock()
			return nil, err2
		}
		if err := e.conn.WriteJSON(appendEvent); err != nil {
			e.mu.Unlock()
			return nil, fmt.Errorf("tts: send input_text_buffer.append: %w", err)
		}
	}
	log.Printf("tts: sent input_text_buffer.append (%d chars)", len([]rune(text)))

	// Commit to trigger synthesis.
	commitEvent := map[string]interface{}{
		"event_id": fmt.Sprintf("event_%d", time.Now().UnixNano()),
		"type":     "input_text_buffer.commit",
	}
	if err := e.conn.WriteJSON(commitEvent); err != nil {
		e.mu.Unlock()
		return nil, fmt.Errorf("tts: send input_text_buffer.commit: %w", err)
	}
	log.Printf("tts: sent input_text_buffer.commit")

	conn := e.conn
	e.mu.Unlock()

	// Read loop: collect audio deltas until response.done.
	conn.SetReadDeadline(time.Now().Add(30 * time.Second))
	var allSamples []float32
	readErr := e.readAudioLoop(conn, &allSamples)

	if readErr != nil {
		e.mu.Lock()
		e.closeLocked()
		e.mu.Unlock()
		return nil, readErr
	}

	dur := float64(len(allSamples)) / float64(e.sampleRate)
	log.Printf("tts: online synthesized %d samples (%.1fs) for %d chars",
		len(allSamples), dur, len([]rune(text)))
	log.Printf("[timing] TTS: total=%dms", time.Since(t0).Milliseconds())

	return &SynthesizeResult{
		Samples:    allSamples,
		SampleRate: e.sampleRate,
		Duration:   dur,
	}, nil
}

// ensureConnectedLocked connects to the TTS API and performs session setup.
// Must be called with e.mu held.
func (e *Engine) ensureConnectedLocked() error {
	if e.conn != nil {
		return nil
	}

	t0 := time.Now()
	wsURL := fmt.Sprintf("%s?model=%s", e.onlineURL, e.onlineModel)
	header := make(http.Header)
	header.Set("Authorization", "Bearer "+e.onlineAPIKey)

	conn, resp, err := e.dialer.Dial(wsURL, header)
	if err != nil {
		if resp != nil {
			return fmt.Errorf("tts: websocket dial HTTP %d: %w", resp.StatusCode, err)
		}
		return fmt.Errorf("tts: websocket dial: %w", err)
	}
	log.Printf("tts: connected to %s (%dms)", wsURL, time.Since(t0).Milliseconds())

	// Wait for session.created.
	_, msg, err := conn.ReadMessage()
	if err != nil {
		conn.Close()
		return fmt.Errorf("tts: wait session.created: %w", err)
	}
	var event map[string]interface{}
	if err := json.Unmarshal(msg, &event); err != nil {
		conn.Close()
		return fmt.Errorf("tts: parse session.created: %w", err)
	}
	et, _ := event["type"].(string)
	if et != "session.created" {
		conn.Close()
		return fmt.Errorf("tts: expected session.created, got %q", et)
	}
	sess, _ := event["session"].(map[string]interface{})
	sid, _ := sess["id"].(string)
	log.Printf("tts: session.created id=%s", sid)

	// Send session.update (commit mode).
	updateEvent := map[string]interface{}{
		"event_id": fmt.Sprintf("event_%d", time.Now().UnixNano()),
		"type":     "session.update",
		"session": map[string]interface{}{
			"voice":           e.onlineVoice,
			"mode":            "commit",
			"language_type":   "Chinese",
			"response_format": e.onlineFormat,
			"sample_rate":     e.onlineSampleRate,
		},
	}
	if err := conn.WriteJSON(updateEvent); err != nil {
		conn.Close()
		return fmt.Errorf("tts: send session.update: %w", err)
	}
	log.Printf("tts: sent session.update (voice=%s, mode=commit, format=%s, rate=%d)",
		e.onlineVoice, e.onlineFormat, e.onlineSampleRate)

	// Wait for session.updated.
	_, msg, err = conn.ReadMessage()
	if err != nil {
		conn.Close()
		return fmt.Errorf("tts: wait session.updated: %w", err)
	}
	if err := json.Unmarshal(msg, &event); err != nil {
		conn.Close()
		return fmt.Errorf("tts: parse session.updated: %w", err)
	}
	et, _ = event["type"].(string)
	if et == "error" {
		errObj, _ := event["error"].(map[string]interface{})
		code, _ := errObj["code"].(string)
		errMsg, _ := errObj["message"].(string)
		conn.Close()
		return fmt.Errorf("tts: session.update error [%s]: %s", code, errMsg)
	}
	if et != "session.updated" {
		conn.Close()
		return fmt.Errorf("tts: expected session.updated, got %q", et)
	}
	log.Printf("tts: session.updated")

	e.conn = conn
	log.Printf("[timing] TTS: ws_connect+handshake=%dms", time.Since(t0).Milliseconds())
	return nil
}

// readAudioLoop reads messages from the connection until response.done,
// collecting audio deltas along the way.
func (e *Engine) readAudioLoop(conn *websocket.Conn, allSamples *[]float32) error {
	for {
		_, msg, err := conn.ReadMessage()
		if err != nil {
			return fmt.Errorf("tts: read message: %w", err)
		}

		var event map[string]interface{}
		if err := json.Unmarshal(msg, &event); err != nil {
			log.Printf("tts: parse event: %v", err)
			continue
		}

		eventType, _ := event["type"].(string)

		switch eventType {
		case "response.audio.delta":
			deltaB64, _ := event["delta"].(string)
			if deltaB64 == "" {
				continue
			}
			raw, err := base64.StdEncoding.DecodeString(deltaB64)
			if err != nil {
				log.Printf("tts: decode base64 audio: %v", err)
				continue
			}
			samples := pcmToFloat32(raw)
			*allSamples = append(*allSamples, samples...)

		case "response.audio.done":
			log.Printf("tts: response.audio.done")

		case "response.done":
			log.Printf("tts: response.done")
			return nil

		case "error":
			errObj, _ := event["error"].(map[string]interface{})
			code, _ := errObj["code"].(string)
			errMsg, _ := errObj["message"].(string)
			return fmt.Errorf("tts: server error [%s]: %s", code, errMsg)

		default:
			// response.created, response.output_item.added, etc. — skip.
		}
	}
}

// closeLocked force-closes the connection.
// Must be called with e.mu held.
func (e *Engine) closeLocked() {
	if e.conn != nil {
		e.conn.Close()
		e.conn = nil
	}
}

// SampleRate returns the engine's sample rate.
func (e *Engine) SampleRate() int {
	if e.sampleRate > 0 {
		return e.sampleRate
	}
	return 22050 // default
}

// Close releases the engine and closes the WebSocket connection gracefully.
func (e *Engine) Close() {
	e.reqMu.Lock()
	defer e.reqMu.Unlock()

	e.mu.Lock()
	defer e.mu.Unlock()

	if e.conn != nil {
		// Best-effort: send session.finish.
		finishEvent := map[string]interface{}{
			"event_id": fmt.Sprintf("event_%d", time.Now().UnixNano()),
			"type":     "session.finish",
		}
		e.conn.SetWriteDeadline(time.Now().Add(3 * time.Second))
		if err := e.conn.WriteJSON(finishEvent); err != nil {
			log.Printf("tts: session.finish write failed: %v", err)
		}

		// Read until session.finished or timeout.
		e.conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		for {
			_, msg, err := e.conn.ReadMessage()
			if err != nil {
				break
			}
			var event map[string]interface{}
			if json.Unmarshal(msg, &event) == nil {
				if t, _ := event["type"].(string); t == "session.finished" {
					log.Printf("tts: session.finished (clean close)")
					break
				}
			}
		}

		closeMsg := websocket.FormatCloseMessage(websocket.CloseNormalClosure, "")
		e.conn.SetWriteDeadline(time.Now().Add(3 * time.Second))
		_ = e.conn.WriteMessage(websocket.CloseMessage, closeMsg)
		e.conn.Close()
		e.conn = nil
	}

	if e.tts != nil {
		sherpa.DeleteOfflineTts(e.tts)
		e.tts = nil
	}
}

// pcmToFloat32 converts int16 little-endian PCM bytes to float32 samples in [-1, 1].
func pcmToFloat32(data []byte) []float32 {
	count := len(data) / 2
	samples := make([]float32, count)
	for i := range count {
		v := int16(binary.LittleEndian.Uint16(data[i*2:]))
		samples[i] = float32(v) / math.MaxInt16
	}
	return samples
}

// ModelsDir returns the default path to TTS models.
func ModelsDir() string {
	candidates := []string{
		"models/tts",
		"../models/tts",
		filepath.Join(filepath.Dir(os.Args[0]), "models/tts"),
	}
	for _, d := range candidates {
		if _, err := os.Stat(filepath.Join(d, "model.onnx")); err == nil {
			return d
		}
	}
	return "models/tts"
}