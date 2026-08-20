// Package kws wraps the sherpa-onnx keyword spotting engine for
// wake word detection ("小火小火").
package kws

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"

	sherpa "github.com/k2-fsa/sherpa-onnx-go/sherpa_onnx"
)

// WakeWord is the Chinese wake word in sherpa keyword format.
// "x iǎo h uǒ x iǎo h uǒ @小火小火" means the phoneme sequence
// followed by the display name.
const WakeWord = "x iǎo h uǒ x iǎo h uǒ @小火小火"

// Engine wraps the sherpa-onnx KeywordSpotter for wake word detection.
type Engine struct {
	spotter  *sherpa.KeywordSpotter
	keyword  string
	modelDir string
	stream   *sherpa.OnlineStream // internal stream for continuous detection
}

// New creates a new KWS engine with the given model directory.
// It searches for encoder/decoder/joiner/onnx files by keyword.
func New(modelDir string) (*Engine, error) {
	// Find model files by keyword (same approach as iOS/Android).
	encoder := findFile(modelDir, "encoder", ".onnx")
	decoder := findFile(modelDir, "decoder", ".onnx")
	joiner := findFile(modelDir, "joiner", ".onnx")
	tokens := findFile(modelDir, "tokens", ".txt")

	for _, f := range []string{encoder, decoder, joiner, tokens} {
		if f == "" {
			return nil, fmt.Errorf("kws: missing model file in %s", modelDir)
		}
	}

	log.Printf("kws: encoder=%s", encoder)
	log.Printf("kws: decoder=%s", decoder)
	log.Printf("kws: joiner=%s", joiner)
	log.Printf("kws: tokens=%s", tokens)

	numThreads := 1 // keep low, runs concurrently with ASR/TTS.

	config := &sherpa.KeywordSpotterConfig{
		FeatConfig: sherpa.FeatureConfig{
			SampleRate: 16000,
			FeatureDim: 80,
		},
		ModelConfig: sherpa.OnlineModelConfig{
			Transducer: sherpa.OnlineTransducerModelConfig{
				Encoder: encoder,
				Decoder: decoder,
				Joiner:  joiner,
			},
			Tokens:     tokens,
			NumThreads: numThreads,
			Provider:   "cpu",
			Debug:      0,
		},
		MaxActivePaths:    2,
		KeywordsScore:     6.0,
		KeywordsThreshold: 0.05,
		KeywordsBuf:       WakeWord,
		KeywordsBufSize:   len(WakeWord),
	}

	spotter := sherpa.NewKeywordSpotter(config)
	if spotter == nil {
		return nil, fmt.Errorf("kws: failed to create keyword spotter")
	}

	stream := sherpa.NewKeywordStream(spotter)
	if stream == nil {
		sherpa.DeleteKeywordSpotter(spotter)
		return nil, fmt.Errorf("kws: failed to create keyword stream")
	}

	log.Printf("kws: engine created, keywords=%q, num_threads=%d", WakeWord, numThreads)

	return &Engine{
		spotter:  spotter,
		keyword:  WakeWord,
		modelDir: modelDir,
		stream:   stream,
	}, nil
}

// ProcessSamples feeds audio samples to the keyword spotter and returns
// the detected keyword (empty string if no detection).
func (e *Engine) ProcessSamples(samples []float32) string {
	if e.stream == nil {
		return ""
	}
	e.stream.AcceptWaveform(16000, samples)
	for e.spotter.IsReady(e.stream) {
		e.spotter.Decode(e.stream)
		result := e.spotter.GetResult(e.stream)
		if result.Keyword != "" {
			e.spotter.Reset(e.stream)
			return result.Keyword
		}
	}
	return ""
}

// Close releases the engine.
func (e *Engine) Close() {
	if e.stream != nil {
		sherpa.DeleteOnlineStream(e.stream)
		e.stream = nil
	}
	if e.spotter != nil {
		sherpa.DeleteKeywordSpotter(e.spotter)
		e.spotter = nil
	}
}

// ModelsDir returns the default path to KWS models.
func ModelsDir() string {
	candidates := []string{
		"models/kws",
		"../models/kws",
		filepath.Join(filepath.Dir(os.Args[0]), "models/kws"),
	}
	for _, d := range candidates {
		if _, err := os.Stat(d); err == nil {
			return d
		}
	}
	return "models/kws"
}

// findFile searches a directory for a file whose name contains the keyword
// and ends with the given suffix. This handles model files with epoch/avg
// suffixes in their names.
func findFile(dir, keyword, suffix string) string {
	// Try the standard name first: keyword + suffix (e.g. "encoder.onnx").
	stdName := filepath.Join(dir, keyword+suffix)
	if _, err := os.Stat(stdName); err == nil {
		return stdName
	}

	// Fallback: scan directory for a file containing the keyword.
	entries, err := os.ReadDir(dir)
	if err != nil {
		return ""
	}
	for _, entry := range entries {
		name := entry.Name()
		if strings.Contains(name, keyword) && strings.HasSuffix(name, suffix) {
			return filepath.Join(dir, name)
		}
	}
	return ""
}