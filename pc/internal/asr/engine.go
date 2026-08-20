// Package asr wraps the sherpa-onnx offline ASR engine for
// SenseVoiceSmall speech recognition.
package asr

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime"

	sherpa "github.com/k2-fsa/sherpa-onnx-go/sherpa_onnx"
)

// Engine wraps the sherpa-onnx offline ASR engine (SenseVoiceSmall).
type Engine struct {
	recognizer *sherpa.OfflineRecognizer
	sampleRate int
}

// ModelPaths holds the required model file paths for SenseVoiceSmall.
type ModelPaths struct {
	Model  string // model.int8.onnx
	Tokens string // tokens.txt
}

// New creates a new ASR engine with the given model paths.
func New(p ModelPaths) (*Engine, error) {
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

	log.Printf("asr: engine created, num_threads=%d", numThreads)

	return &Engine{
		recognizer: recognizer,
		sampleRate: 16000,
	}, nil
}

// Result contains the recognition result plus metadata.
type Result struct {
	// Text is the recognized Chinese text.
	Text string
	// Lang is the detected language (e.g. "zh", "en", "ja").
	Lang string
	// Emotion is the detected emotion from SenseVoice (e.g. "neutral", "happy").
	Emotion string
}

// Decode runs recognition on the provided PCM float32 samples.
// samples must be 16kHz mono, normalized in [-1, 1].
func (e *Engine) Decode(samples []float32) (*Result, error) {
	if e.recognizer == nil {
		return nil, fmt.Errorf("asr: engine not initialized")
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

	log.Printf("asr: decoded %d samples → text=%q, lang=%s, emotion=%s",
		len(samples), r.Text, r.Lang, r.Emotion)

	return &Result{
		Text:    r.Text,
		Lang:    r.Lang,
		Emotion: r.Emotion,
	}, nil
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