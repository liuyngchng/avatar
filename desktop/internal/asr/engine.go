// Package asr wraps the speech recognition engine.
// Supports both offline (sherpa-onnx SenseVoiceSmall) and online
// (DashScope Qwen-Audio-3.0-ASR-Flash-Streaming WebSocket) modes.
package asr

import (
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

// Mode is the ASR engine mode.
type Mode string

const (
	ModeOffline Mode = "offline"
	ModeOnline  Mode = "online"
)

// ModelPaths holds the required model file paths for offline ASR.
type ModelPaths struct {
	Model  string // model.int8.onnx
	Tokens string // tokens.txt
}

// Engine wraps an ASR engine (offline or online).
type Engine struct {
	mode       Mode
	recognizer *sherpa.OfflineRecognizer // offline only
	sampleRate int

	// Online ASR config (DashScope WebSocket).
	onlineURL        string
	onlineModel      string
	onlineAPIKey     string
	onlineFormat     string
	onlineSampleRate int

	// Online WebSocket connection (lazy, reused).
	mu     sync.Mutex
	conn   *websocket.Conn
	reqMu  sync.Mutex
	dialer *websocket.Dialer
}

// Result contains the recognition result plus metadata.
type Result struct {
	Text    string // recognized text
	Lang    string // detected language (e.g. "zh", "en")
	Emotion string // detected emotion (e.g. "neutral", "happy")
}

// New creates a new ASR engine.
// If mode is "online", p is ignored and the online API is used.
// If mode is "offline", p must contain valid model paths.
// proxyFunc is the http.Proxy function used for the WebSocket connection
// in online mode (e.g. config.ProxyFunc(cfg.Proxy)).
func New(mode Mode, p ModelPaths, onlineURL, onlineModel, onlineAPIKey string, onlineFormat string, onlineSampleRate int, proxyFunc func(*http.Request) (*url.URL, error)) (*Engine, error) {
	e := &Engine{
		mode:             mode,
		sampleRate:       16000,
		onlineURL:        onlineURL,
		onlineModel:      onlineModel,
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
			return nil, fmt.Errorf("asr: online mode requires url and api_key")
		}
		if onlineFormat == "" {
			e.onlineFormat = "pcm"
		}
		if onlineSampleRate <= 0 {
			e.onlineSampleRate = 16000
		}
		log.Printf("asr: using online engine (DashScope), model=%s", onlineModel)
		return e, nil
	}

	// Offline mode: initialize sherpa-onnx.
	for _, f := range []string{p.Model, p.Tokens} {
		if _, err := os.Stat(f); err != nil {
			return nil, fmt.Errorf("asr: model file not found: %s", f)
		}
	}

	numThreads := runtime.NumCPU()
	if numThreads > 4 {
		numThreads = 4
	}
	if numThreads < 2 {
		numThreads = 2
	}

	config := &sherpa.OfflineRecognizerConfig{
		FeatConfig: sherpa.FeatureConfig{
			SampleRate: 16000,
			FeatureDim: 80,
		},
		ModelConfig: sherpa.OfflineModelConfig{
			SenseVoice: sherpa.OfflineSenseVoiceModelConfig{
				Model:                       p.Model,
				Language:                    "auto",
				UseInverseTextNormalization: 1,
			},
			Tokens:     p.Tokens,
			NumThreads: numThreads,
			Provider:   "cpu",
			Debug:      0,
		},
		DecodingMethod: "greedy_search",
	}

	recognizer := sherpa.NewOfflineRecognizer(config)
	if recognizer == nil {
		return nil, fmt.Errorf("asr: failed to create recognizer (check model paths)")
	}

	e.recognizer = recognizer
	log.Printf("asr: offline engine created, num_threads=%d", numThreads)
	return e, nil
}

// Decode runs recognition on the provided PCM float32 samples.
// samples must be 16kHz mono, normalized in [-1, 1].
func (e *Engine) Decode(samples []float32) (*Result, error) {
	if e.mode == ModeOnline {
		return e.decodeOnline(samples)
	}
	return e.decodeOffline(samples)
}

func (e *Engine) decodeOffline(samples []float32) (*Result, error) {
	if e.recognizer == nil {
		return nil, fmt.Errorf("asr: offline engine not initialized")
	}
	if len(samples) == 0 {
		return nil, fmt.Errorf("asr: no samples provided")
	}

	stream := sherpa.NewOfflineStream(e.recognizer)
	if stream == nil {
		return nil, fmt.Errorf("asr: failed to create offline stream")
	}
	defer sherpa.DeleteOfflineStream(stream)

	stream.AcceptWaveform(e.sampleRate, samples)
	e.recognizer.Decode(stream)

	r := stream.GetResult()
	if r == nil {
		return nil, fmt.Errorf("asr: no result")
	}

	log.Printf("asr: offline decoded %d samples → text=%q, lang=%s, emotion=%s",
		len(samples), r.Text, r.Lang, r.Emotion)

	return &Result{
		Text:    r.Text,
		Lang:    r.Lang,
		Emotion: r.Emotion,
	}, nil
}

// decodeOnline sends audio to the DashScope ASR WebSocket API.
func (e *Engine) decodeOnline(samples []float32) (*Result, error) {
	e.reqMu.Lock()
	defer e.reqMu.Unlock()

	t0 := time.Now()

	e.mu.Lock()
	if err := e.ensureConnectedLocked(); err != nil {
		e.mu.Unlock()
		return nil, err
	}
	e.conn.SetReadDeadline(time.Now().Add(30 * time.Second))

	taskID := generateID()

	runTask := map[string]interface{}{
		"header": map[string]interface{}{
			"action":    "run-task",
			"task_id":   taskID,
			"streaming": "duplex",
		},
		"payload": map[string]interface{}{
			"task_group": "audio",
			"task":       "asr",
			"function":   "recognition",
			"model":      e.onlineModel,
			"parameters": map[string]interface{}{
				"sample_rate": e.onlineSampleRate,
				"format":      e.onlineFormat,
			},
			"input": map[string]interface{}{},
		},
	}
	if err := e.conn.WriteJSON(runTask); err != nil {
		log.Printf("asr: write run-task failed, reconnecting: %v", err)
		e.closeLocked()
		if err2 := e.ensureConnectedLocked(); err2 != nil {
			e.mu.Unlock()
			return nil, err2
		}
		if err := e.conn.WriteJSON(runTask); err != nil {
			e.mu.Unlock()
			return nil, fmt.Errorf("asr: send run-task: %w", err)
		}
	}
	log.Printf("asr: sent run-task (task=%s, model=%s)", taskID, e.onlineModel)

	conn := e.conn
	e.mu.Unlock()

	var finalText string
	taskStarted := false
	audioSent := false
	done := make(chan struct{})
	var readErr error

	go func() {
		defer close(done)
		for {
			msgType, msg, err := conn.ReadMessage()
			if err != nil {
				if websocket.IsCloseError(err, websocket.CloseNormalClosure) {
					return
				}
				readErr = fmt.Errorf("asr: read message: %w", err)
				return
			}
			if msgType != websocket.TextMessage {
				continue
			}

			var event map[string]interface{}
			if err := json.Unmarshal(msg, &event); err != nil {
				log.Printf("asr: parse event: %v", err)
				continue
			}

			header, _ := event["header"].(map[string]interface{})
			eventName, _ := header["event"].(string)

			switch eventName {
			case "task-started":
				log.Printf("asr: task-started")
				taskStarted = true
				if !audioSent {
					audioSent = true
					go func() {
						if err := e.sendAudio(conn, samples, e.onlineSampleRate); err != nil {
							log.Printf("asr: send audio: %v", err)
						}
						finishTask := map[string]interface{}{
							"header": map[string]interface{}{
								"action":    "finish-task",
								"task_id":   taskID,
								"streaming": "duplex",
							},
							"payload": map[string]interface{}{
								"input": map[string]interface{}{},
							},
						}
						if err := conn.WriteJSON(finishTask); err != nil {
							log.Printf("asr: send finish-task: %v", err)
						}
						log.Printf("asr: sent finish-task")
					}()
				}

			case "result-generated":
				payload, _ := event["payload"].(map[string]interface{})
				output, _ := payload["output"].(map[string]interface{})
				sentence, _ := output["sentence"].(map[string]interface{})
				text, _ := sentence["text"].(string)
				sentenceEnd, _ := sentence["sentence_end"].(bool)
				if sentenceEnd {
					if finalText != "" {
						finalText += " "
					}
					finalText += text
				}

			case "task-finished":
				log.Printf("asr: task-finished")
				return

			case "task-failed":
				errMsg, _ := header["error_message"].(string)
				readErr = fmt.Errorf("asr: task failed: %s", errMsg)
				return

			default:
				log.Printf("asr: unknown event: %s", eventName)
			}
		}
	}()

	<-done

	if readErr != nil {
		e.mu.Lock()
		e.closeLocked()
		e.mu.Unlock()
		return nil, readErr
	}

	if !taskStarted {
		e.mu.Lock()
		e.closeLocked()
		e.mu.Unlock()
		return nil, fmt.Errorf("asr: task never started")
	}

	log.Printf("asr: online final text: %q", finalText)
	log.Printf("[timing] ASR: total=%dms", time.Since(t0).Milliseconds())

	// Close the connection after each request. DashScope's WebSocket ASR
	// closes the socket server-side after task-finished, so reusing it for
	// the next turn fails ("task never started"). Reconnect fresh each time.
	e.mu.Lock()
	e.closeLocked()
	e.mu.Unlock()

	return &Result{
		Text:    finalText,
		Lang:    "zh",
		Emotion: "neutral",
	}, nil
}

// ensureConnectedLocked connects to the DashScope ASR WebSocket API.
// Must be called with e.mu held.
func (e *Engine) ensureConnectedLocked() error {
	if e.conn != nil {
		return nil
	}

	t0 := time.Now()
	header := make(http.Header)
	header.Set("Authorization", "Bearer "+e.onlineAPIKey)

	conn, resp, err := e.dialer.Dial(e.onlineURL, header)
	if err != nil {
		if resp != nil {
			return fmt.Errorf("asr: websocket dial HTTP %d: %w", resp.StatusCode, err)
		}
		return fmt.Errorf("asr: websocket dial: %w", err)
	}
	e.conn = conn
	log.Printf("[timing] ASR: ws_connect=%dms", time.Since(t0).Milliseconds())
	return nil
}

// sendAudio converts float32 samples to int16 PCM and sends them as binary
// WebSocket frames in chunks.
func (e *Engine) sendAudio(conn *websocket.Conn, samples []float32, sampleRate int) error {
	pcm := float32ToPCM(samples)

	chunkSize := sampleRate * 2 / 10 // ~100ms chunks
	if chunkSize < 1 {
		chunkSize = 3200
	}

	for offset := 0; offset < len(pcm); offset += chunkSize {
		end := offset + chunkSize
		if end > len(pcm) {
			end = len(pcm)
		}
		chunk := pcm[offset:end]
		if err := conn.WriteMessage(websocket.BinaryMessage, chunk); err != nil {
			return fmt.Errorf("send binary audio: %w", err)
		}
	}

	log.Printf("asr: sent %d bytes PCM audio in %d-byte chunks", len(pcm), chunkSize)
	return nil
}

// closeLocked force-closes the connection.
// Must be called with e.mu held.
func (e *Engine) closeLocked() {
	if e.conn != nil {
		e.conn.Close()
		e.conn = nil
	}
}

// Close releases the engine and closes the WebSocket connection gracefully.
func (e *Engine) Close() {
	e.reqMu.Lock()
	defer e.reqMu.Unlock()

	e.mu.Lock()
	defer e.mu.Unlock()

	if e.conn != nil {
		closeMsg := websocket.FormatCloseMessage(websocket.CloseNormalClosure, "")
		e.conn.SetWriteDeadline(time.Now().Add(3 * time.Second))
		_ = e.conn.WriteMessage(websocket.CloseMessage, closeMsg)
		e.conn.Close()
		e.conn = nil
	}

	if e.recognizer != nil {
		sherpa.DeleteOfflineRecognizer(e.recognizer)
		e.recognizer = nil
	}
}

// SampleRate returns the engine's expected sample rate (16000 Hz).
func (e *Engine) SampleRate() int {
	return e.sampleRate
}

// float32ToPCM converts float32 samples in [-1, 1] to int16 little-endian PCM bytes.
func float32ToPCM(samples []float32) []byte {
	buf := make([]byte, len(samples)*2)
	for i, s := range samples {
		if s > 1.0 {
			s = 1.0
		} else if s < -1.0 {
			s = -1.0
		}
		v := int16(s * math.MaxInt16)
		binary.LittleEndian.PutUint16(buf[i*2:], uint16(v))
	}
	return buf
}

// generateID creates a short random hex ID for task identification.
func generateID() string {
	return fmt.Sprintf("%016x", time.Now().UnixNano())
}

// ModelsDir returns the default path to ASR models.
func ModelsDir() string {
	candidates := []string{
		"models/asr",
		"../models/asr",
		filepath.Join(filepath.Dir(os.Args[0]), "models/asr"),
	}
	for _, d := range candidates {
		if _, err := os.Stat(filepath.Join(d, "model.int8.onnx")); err == nil {
			return d
		}
	}
	return "models/asr"
}