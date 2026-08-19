// Package main is the entry point for the Avatar PC application.
// It creates a window (WebView2 on Windows, Lorca on Linux) and
// loads the 3D digital human rendering page.
//
// Configuration is read from cfg.yml in the same directory as the
// executable. See cfg.yml for the available options.
package main

import (
	"embed"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/liuyngchng/avatar-pc/internal/asr"
	"github.com/liuyngchng/avatar-pc/internal/audio"
	"github.com/liuyngchng/avatar-pc/internal/brain"
	"github.com/liuyngchng/avatar-pc/internal/config"
	"github.com/liuyngchng/avatar-pc/internal/llm"
	"github.com/liuyngchng/avatar-pc/internal/renderer"
	"github.com/liuyngchng/avatar-pc/internal/tts"
)

//go:embed web
var webAssets embed.FS

func main() {
	log.SetFlags(log.Ltime | log.Lshortfile)
	log.Println("Avatar PC starting...")

	// Load configuration from cfg.yml.
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	// Initialize online clients (Alibaba Cloud Bailian APIs).
	asrClient := asr.NewClient(cfg.ASR.URL, cfg.ASR.Model, cfg.APIKey)
	defer asrClient.Close()

	llmClient := llm.NewClient(cfg.LLM.URL, cfg.LLM.Model, cfg.APIKey)
	defer llmClient.Close()

	ttsClient := tts.NewClient(cfg.TTS.URL, cfg.TTS.Model, cfg.TTS.Voice, cfg.APIKey)
	defer ttsClient.Close()

	log.Printf("main: ASR endpoint=%s (model=%s)", cfg.ASR.URL, cfg.ASR.Model)
	log.Printf("main: LLM endpoint=%s (model=%s)", cfg.LLM.URL, cfg.LLM.Model)
	log.Printf("main: TTS endpoint=%s (model=%s, voice=%s)", cfg.TTS.URL, cfg.TTS.Model, cfg.TTS.Voice)

	// Initialize audio player.
	player, err := audio.NewPlayer(ttsClient.SampleRate())
	if err != nil {
		log.Fatalf("Failed to create audio player: %v", err)
	}
	player.WaitReady()
	defer player.Close()

	// Initialize audio recorder (platform-specific: WASAPI on Windows, malgo on Linux).
	recorder := audio.NewRecorder()

	// Create the renderer window (platform-specific).
	r, err := renderer.New(webAssets)
	if err != nil {
		log.Fatalf("Failed to create renderer: %v", err)
	}
	defer r.Close()

	// Create the brain (state machine).
	sm := brain.NewStateMachine(ttsClient, asrClient, llmClient, player, recorder)

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