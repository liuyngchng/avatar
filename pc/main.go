// Package main is the entry point for the Avatar PC application.
// It creates a window (WebView2 on Windows, Lorca on Linux) and
// loads the 3D digital human rendering page.
package main

import (
	"embed"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/liuyngchng/avatar-pc/internal/audio"
	"github.com/liuyngchng/avatar-pc/internal/brain"
	"github.com/liuyngchng/avatar-pc/internal/renderer"
	"github.com/liuyngchng/avatar-pc/internal/tts"
)

//go:embed web
var webAssets embed.FS

func main() {
	log.SetFlags(log.Ltime | log.Lshortfile)
	log.Println("Avatar PC starting...")

	// Initialize TTS engine (Matcha-TTS + vocos).
	ttsDir := tts.ModelsDir()
	ttsEngine, err := tts.New(tts.ModelPaths{
		AcousticModel: filepath.Join(ttsDir, "model.onnx"),
		Vocoder:       filepath.Join(ttsDir, "vocos.onnx"),
		Tokens:        filepath.Join(ttsDir, "tokens.txt"),
		Lexicon:       filepath.Join(ttsDir, "lexicon.txt"),
	})
	if err != nil {
		log.Fatalf("Failed to create TTS engine: %v", err)
	}
	defer ttsEngine.Close()

	// Initialize audio player.
	player, err := audio.NewPlayer(ttsEngine.SampleRate())
	if err != nil {
		log.Fatalf("Failed to create audio player: %v", err)
	}
	player.WaitReady()
	defer player.Close()

	// Create the renderer window (platform-specific).
	r, err := renderer.New(webAssets)
	if err != nil {
		log.Fatalf("Failed to create renderer: %v", err)
	}
	defer r.Close()

	// Create the brain (state machine).
	sm := brain.NewStateMachine(ttsEngine, player)

	// Start the FSM loop.
	go sm.Run()

	// Handle incoming events from the renderer (user taps, etc.).
	go func() {
		for msg := range r.Events() {
			sm.HandleEvent(msg)
		}
	}()

	// Forward brain state changes to the renderer.
	go func() {
		for state := range sm.StateChanges() {
			r.SendMessage(state)
		}
	}()

	// Forward viseme events to the renderer for lip-sync.
	go func() {
		for vis := range sm.Visemes() {
			r.SendMessage(vis)
		}
	}()

	// Wait for SIGINT or SIGTERM.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh

	log.Println("Avatar PC shutting down...")
}