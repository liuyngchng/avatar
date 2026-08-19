// Package tts wraps the sherpa-onnx offline TTS engine for
// Matcha-TTS + vocos Chinese speech synthesis.
package tts

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime"

	sherpa "github.com/k2-fsa/sherpa-onnx-go/sherpa_onnx"
)

// Engine wraps the sherpa-onnx offline TTS engine.
type Engine struct {
	tts        *sherpa.OfflineTts
	sampleRate int
}

// ModelPaths holds the required model file paths for Matcha-TTS.
type ModelPaths struct {
	AcousticModel string // model.onnx (Matcha acoustic model)
	Vocoder       string // vocos.onnx
	Tokens        string // tokens.txt
	Lexicon       string // lexicon.txt
}

// New creates a new TTS engine with the given model paths.
func New(p ModelPaths) (*Engine, error) {
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

	sr := tts.SampleRate()
	log.Printf("tts: engine created, sample_rate=%d, num_threads=%d", sr, numThreads)

	return &Engine{
		tts:        tts,
		sampleRate: sr,
	}, nil
}

// synthesizeResult contains the result of a TTS synthesis.
type SynthesizeResult struct {
	// Samples are normalized float32 PCM samples in [-1, 1].
	Samples []float32
	// SampleRate is the sample rate in Hz (typically 22050).
	SampleRate int
	// Duration is the audio duration in seconds.
	Duration float64
}

// Synthesize converts text to speech.
func (e *Engine) Synthesize(text string, speed float32) (*SynthesizeResult, error) {
	if speed <= 0 {
		speed = 1.0
	}

	audio := e.tts.Generate(text, 0 /* sid */, speed)
	if audio == nil {
		return nil, fmt.Errorf("tts: synthesis produced no audio")
	}

	dur := float64(len(audio.Samples)) / float64(audio.SampleRate)
	log.Printf("tts: synthesized %d samples (%.1fs) for %d chars",
		len(audio.Samples), dur, len([]rune(text)))

	return &SynthesizeResult{
		Samples:    audio.Samples,
		SampleRate: audio.SampleRate,
		Duration:   dur,
	}, nil
}

// SampleRate returns the engine's sample rate.
func (e *Engine) SampleRate() int {
	return e.sampleRate
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
	// Relative to the working directory (where the binary runs).
	// In dev: repo/pc/models/tts
	// In prod: alongside the binary
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