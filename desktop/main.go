// Package main is the entry point for the Avatar PC application.
// It creates a window (WebKitGTK on Linux) and
// loads the 3D digital human rendering page.
package main

import (
	"embed"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/liuyngchng/avatar-desktop/internal/asr"
	"github.com/liuyngchng/avatar-desktop/internal/audio"
	"github.com/liuyngchng/avatar-desktop/internal/brain"
	"github.com/liuyngchng/avatar-desktop/internal/config"
	"github.com/liuyngchng/avatar-desktop/internal/kws"
	"github.com/liuyngchng/avatar-desktop/internal/llm"
	"github.com/liuyngchng/avatar-desktop/internal/renderer"
	"github.com/liuyngchng/avatar-desktop/internal/tts"
)

//go:embed web
var webAssets embed.FS

func main() {
	log.SetFlags(log.Ltime | log.Lshortfile)
	log.Println("Avatar PC starting...")

	// ── Load config ────────────────────────────────────────
	cfg, err := config.Load()
	if err != nil {
		log.Printf("Warning: cfg.yml 加载失败 — 无法进行对话，数字人将使用默认响应 (error: %v)", err)
		cfg = &config.Config{
			LLM: config.LLMConfig{
				BaseURL: os.Getenv("AVATAR_LLM_BASE_URL"),
				APIKey:  os.Getenv("AVATAR_LLM_API_KEY"),
				Model:   os.Getenv("AVATAR_LLM_MODEL"),
				Name:    "小然",
			},
		}
	}
	// Env vars override config file values.
	if v := os.Getenv("AVATAR_LLM_BASE_URL"); v != "" {
		cfg.LLM.BaseURL = v
	}
	if v := os.Getenv("AVATAR_LLM_API_KEY"); v != "" {
		cfg.LLM.APIKey = v
	}
	if v := os.Getenv("AVATAR_LLM_MODEL"); v != "" {
		cfg.LLM.Model = v
	}
	// Default character name (used in system prompt and wake word).
	if cfg.LLM.Name == "" {
		cfg.LLM.Name = "小然"
	}

	// Print proxy state so the user knows at a glance.
	log.Printf("main: %s", config.ProxyDesc(cfg.Proxy, cfg.ProxyDisabled))

	// ── Initialize TTS engine (offline Matcha-TTS or online Qwen-TTS) ──
	ttsDir := tts.ModelsDir()
	ttsMode := tts.Mode(cfg.TTS.Mode)
	ttsEngine, err := tts.New(ttsMode, tts.ModelPaths{
		AcousticModel: filepath.Join(ttsDir, "model.onnx"),
		Vocoder:       filepath.Join(ttsDir, "vocos.onnx"),
		Tokens:        filepath.Join(ttsDir, "tokens.txt"),
		Lexicon:       filepath.Join(ttsDir, "lexicon.txt"),
	}, cfg.TTS.URL, cfg.TTS.Model, cfg.TTS.Voice, cfg.APIKey, cfg.TTS.Format, cfg.TTS.SampleRate, config.ProxyFunc(cfg.Proxy, cfg.ProxyDisabled))
	if err != nil {
		log.Fatalf("Failed to create TTS engine: %v", err)
	}
	defer ttsEngine.Close()

	// Print TTS mode prominently.
	log.Printf("══════════════════════════════════════")
	if ttsMode == tts.ModeOnline {
		log.Printf("  TTS 语音合成: 在线模式 (阿里云百炼 Qwen-TTS)")
	} else {
		log.Printf("  TTS 语音合成: 离线模式 (本地 Matcha-TTS)")
	}
	log.Printf("══════════════════════════════════════")

	// ── Initialize audio player ──────────────────────────────
	player, err := audio.NewPlayer(ttsEngine.SampleRate())
	if err != nil {
		log.Fatalf("Failed to create audio player: %v", err)
	}
	player.WaitReady()
	defer player.Close()

	// ── Initialize ASR engine (offline SenseVoiceSmall or online Qwen-ASR) ──
	asrDir := asr.ModelsDir()
	asrMode := asr.Mode(cfg.ASR.Mode)
	var asrEngine *asr.Engine
	asrEngine, err = asr.New(asrMode, asr.ModelPaths{
		Model:  filepath.Join(asrDir, "model.int8.onnx"),
		Tokens: filepath.Join(asrDir, "tokens.txt"),
	}, cfg.ASR.URL, cfg.ASR.Model, cfg.APIKey, cfg.ASR.Format, cfg.ASR.SampleRate, config.ProxyFunc(cfg.Proxy, cfg.ProxyDisabled))
	if err != nil {
		log.Printf("Warning: ASR engine init failed (continuing without ASR): %v", err)
		asrEngine = nil
	} else {
		defer asrEngine.Close()
	}

	// Print ASR mode prominently.
	log.Printf("══════════════════════════════════════")
	if asrEngine == nil {
		log.Printf("  ASR 语音识别: 未启用 (初始化失败)")
	} else if asrMode == asr.ModeOnline {
		log.Printf("  ASR 语音识别: 在线模式 (阿里云百炼 Qwen-ASR)")
	} else {
		log.Printf("  ASR 语音识别: 离线模式 (本地 SenseVoiceSmall)")
	}
	log.Printf("══════════════════════════════════════")

	// ── Initialize KWS engine (Zipformer wake word) ──────────
	kwsDir := kws.ModelsDir()
	var kwsEngine *kws.Engine

	// Wake word: use the configured value, otherwise auto-generate from the
	// character name (name repeated twice, e.g. "小然" → "小然小然").
	wakeWord := cfg.WakeWord
	if wakeWord == "" {
		wakeWord = kws.GenerateWakeWord(cfg.LLM.Name)
	}
	kwsEngine, err = kws.New(kwsDir, wakeWord)
	if err != nil {
		log.Printf("Warning: KWS engine init failed (continuing without wake word): %v", err)
		kwsEngine = nil
	} else {
		defer kwsEngine.Close()
	}

	// ── Initialize microphone capture ────────────────────────
	capture, err := audio.NewCapture(audio.DefaultCaptureConfig())
	if err != nil {
		log.Printf("Warning: microphone capture init failed (continuing without audio input): %v", err)
		capture = nil
	}
	// Capture is closed by sm.Stop() (it owns the capture lifecycle).

	// ── Initialize LLM client ────────────────────────────────
	// LLM API key: use llm.api_key if set, otherwise fall back to top-level api_key.
	llmAPIKey := cfg.LLM.APIKey
	if llmAPIKey == "" {
		llmAPIKey = cfg.APIKey
	}
	llmClient := llm.New(llm.Config{
		BaseURL:   cfg.LLM.BaseURL,
		APIKey:    llmAPIKey,
		Model:     cfg.LLM.Model,
		Name:      cfg.LLM.Name,
		ProxyFunc: config.ProxyFunc(cfg.Proxy, cfg.ProxyDisabled),
	})
	if llmClient.IsConfigured() {
		log.Println("LLM client configured (streaming enabled)")
	} else {
		log.Println("LLM client NOT configured — set values in cfg.yml. Using fallback responses.")
	}

	// ── Create the renderer window (platform-specific) ──────
	r, err := renderer.New(webAssets, cfg.IsFBXEnabled())
	if err != nil {
		log.Fatalf("Failed to create renderer: %v", err)
	}
	defer r.Close()

	// ── Create the brain (state machine) ─────────────────────
	sm := brain.NewStateMachine(ttsEngine, player, asrEngine, kwsEngine, llmClient, capture, brain.Config{
		NoSpeechTimeout: cfg.NoSpeechTimeout(),
	})
	log.Printf("main: 多轮对话无语音超时 = %s（修改请改 cfg.yml 的 no_speech_timeout_sec）", cfg.NoSpeechTimeout())
	defer sm.Stop() // must run before engine Close()s to avoid use-after-free crashes

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
		for msg := range sm.Outbound() {
			r.SendMessage(msg)
		}
	}()

	// ── Handle SIGINT/SIGTERM by closing the renderer window ──
	// Closing the window quits the GTK main loop on Linux, which
	// unblocks r.Run() below and lets the process shut down cleanly.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Println("Avatar PC shutting down...")
		// Send fade-out before closing.
		r.SendMessage(map[string]string{"cmd": "fade_out"})
		time.Sleep(1100 * time.Millisecond)
		r.Close()
	}()

	// Run the renderer's main loop (blocks until the window closes).
	r.Run()
}