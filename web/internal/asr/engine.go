// Package asr wraps the speech recognition engine.
// Supports both offline (sherpa-onnx SenseVoiceSmall) and online (HTTP API) modes.
package asr

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	sherpa "github.com/k2-fsa/sherpa-onnx-go/sherpa_onnx"
	"github.com/liuyngchng/avatar-web/internal/wav"
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
	// Online ASR config
	onlineBaseURL string
	onlineAPIKey  string
	onlineModel   string
}

// Result contains the recognition result plus metadata.
type Result struct {
	Text    string // recognized text
	Lang    string // detected language
	Emotion string // detected emotion
}

// New creates a new ASR engine.
// If mode is "online", p is ignored and the online API is used.
// If mode is "offline", p must contain valid model paths.
func New(mode Mode, p ModelPaths, onlineBaseURL, onlineAPIKey, onlineModel string) (*Engine, error) {
	e := &Engine{
		mode:          mode,
		sampleRate:    16000,
		onlineBaseURL: onlineBaseURL,
		onlineAPIKey:  onlineAPIKey,
		onlineModel:   onlineModel,
	}

	if mode == ModeOnline {
		if onlineBaseURL == "" || onlineAPIKey == "" {
			return nil, fmt.Errorf("asr: online mode requires base_url and api_key")
		}
		log.Printf("asr: using online engine, model=%s", onlineModel)
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

// decodeOnline sends audio to the online ASR API (OpenAI Whisper compatible:
// POST {base_url}/audio/transcriptions with multipart/form-data).
func (e *Engine) decodeOnline(samples []float32) (*Result, error) {
	wavBytes := wav.Encode(samples, e.sampleRate)

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)

	// file field
	part, err := writer.CreateFormFile("file", "audio.wav")
	if err != nil {
		return nil, fmt.Errorf("asr: create form file: %w", err)
	}
	if _, err := part.Write(wavBytes); err != nil {
		return nil, fmt.Errorf("asr: write wav: %w", err)
	}

	// model field
	model := e.onlineModel
	if model == "" {
		model = "whisper-1"
	}
	if err := writer.WriteField("model", model); err != nil {
		return nil, fmt.Errorf("asr: write model field: %w", err)
	}
	if err := writer.Close(); err != nil {
		return nil, fmt.Errorf("asr: close writer: %w", err)
	}

	url := strings.TrimRight(e.onlineBaseURL, "/") + "/audio/transcriptions"
	req, err := http.NewRequest("POST", url, &body)
	if err != nil {
		return nil, fmt.Errorf("asr: new request: %w", err)
	}
	req.Header.Set("Content-Type", writer.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+e.onlineAPIKey)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("asr: HTTP error: %w", err)
	}
	defer resp.Body.Close()

	respData, err := io.ReadAll(io.LimitReader(resp.Body, 10*1024*1024))
	if err != nil {
		return nil, fmt.Errorf("asr: read response: %w", err)
	}

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("asr: API error %d: %s", resp.StatusCode, truncateBytes(respData, 512))
	}

	var result struct {
		Text     string `json:"text"`
		Language string `json:"language"`
	}
	if err := json.Unmarshal(respData, &result); err != nil {
		return nil, fmt.Errorf("asr: parse response: %w", err)
	}

	text := strings.TrimSpace(result.Text)
	log.Printf("asr: online decoded %d samples → text=%q, lang=%s", len(samples), text, result.Language)

	return &Result{
		Text:    text,
		Lang:    result.Language,
		Emotion: "neutral", // online ASR doesn't provide emotion
	}, nil
}

func truncateBytes(b []byte, max int) string {
	if len(b) <= max {
		return string(b)
	}
	return string(b[:max]) + "..."
}

// SampleRate returns the engine's expected sample rate (16000 Hz).
func (e *Engine) SampleRate() int {
	return e.sampleRate
}

// Close releases the engine.
func (e *Engine) Close() {
	if e.recognizer != nil {
		sherpa.DeleteOfflineRecognizer(e.recognizer)
		e.recognizer = nil
	}
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