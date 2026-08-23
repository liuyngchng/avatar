// Package tts wraps the speech synthesis engine.
// Supports both offline (sherpa-onnx Matcha-TTS) and online (HTTP API) modes.
package tts

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	sherpa "github.com/k2-fsa/sherpa-onnx-go/sherpa_onnx"
	"github.com/liuyngchng/avatar-web/internal/wav"
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
	// Online TTS config
	onlineBaseURL string
	onlineAPIKey  string
	onlineModel   string
	onlineVoice   string
}

// SynthesizeResult contains the result of a TTS synthesis.
type SynthesizeResult struct {
	Samples    []float32 // normalized float32 PCM samples in [-1, 1]
	SampleRate int       // sample rate in Hz (typically 22050)
	Duration   float64   // audio duration in seconds
}

// New creates a new TTS engine.
func New(mode Mode, p ModelPaths, onlineBaseURL, onlineAPIKey, onlineModel, onlineVoice string) (*Engine, error) {
	e := &Engine{
		mode:          mode,
		onlineBaseURL: onlineBaseURL,
		onlineAPIKey:  onlineAPIKey,
		onlineModel:   onlineModel,
		onlineVoice:   onlineVoice,
	}

	if mode == ModeOnline {
		if onlineBaseURL == "" || onlineAPIKey == "" {
			return nil, fmt.Errorf("tts: online mode requires base_url and api_key")
		}
		log.Printf("tts: using online engine, model=%s, voice=%s", onlineModel, onlineVoice)
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

	audio := e.tts.Generate(text, 0, speed)
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

// synthesizeOnline sends text to the online TTS API (OpenAI TTS compatible:
// POST {base_url}/audio/speech → returns audio bytes).
func (e *Engine) synthesizeOnline(text string, speed float32) (*SynthesizeResult, error) {
	voice := e.onlineVoice
	if voice == "" {
		voice = "alloy"
	}
	model := e.onlineModel
	if model == "" {
		model = "tts-1"
	}

	reqBody := map[string]any{
		"model": model,
		"input": text,
		"voice": voice,
		// speed is not supported by all backends; omit if 1.0.
	}
	if speed != 1.0 && speed > 0 {
		reqBody["speed"] = speed
	}

	bodyBytes, err := json.Marshal(reqBody)
	if err != nil {
		return nil, fmt.Errorf("tts: marshal request: %w", err)
	}

	url := strings.TrimRight(e.onlineBaseURL, "/") + "/audio/speech"
	req, err := http.NewRequest("POST", url, bytes.NewReader(bodyBytes))
	if err != nil {
		return nil, fmt.Errorf("tts: new request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+e.onlineAPIKey)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("tts: HTTP error: %w", err)
	}
	defer resp.Body.Close()

	respData, err := io.ReadAll(io.LimitReader(resp.Body, 10*1024*1024))
	if err != nil {
		return nil, fmt.Errorf("tts: read response: %w", err)
	}

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("tts: API error %d: %s", resp.StatusCode, string(respData[:min(len(respData), 512)]))
	}

	// Parse the response as WAV audio.
	samples, sampleRate, err := wav.Decode(respData)
	if err != nil {
		// Maybe it's raw PCM? Try decoding as 16-bit PCM with default rate.
		// For now, just return the error.
		return nil, fmt.Errorf("tts: decode WAV: %w", err)
	}

	dur := float64(len(samples)) / float64(sampleRate)
	log.Printf("tts: online synthesized %d samples (%.1fs) for %d chars, voice=%s",
		len(samples), dur, len([]rune(text)), voice)

	return &SynthesizeResult{
		Samples:    samples,
		SampleRate: sampleRate,
		Duration:   dur,
	}, nil
}

// SampleRate returns the engine's sample rate.
func (e *Engine) SampleRate() int {
	if e.sampleRate > 0 {
		return e.sampleRate
	}
	return 22050 // default
}

// Close releases the engine.
func (e *Engine) Close() {
	if e.tts != nil {
		sherpa.DeleteOfflineTts(e.tts)
		e.tts = nil
	}
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