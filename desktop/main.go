// Package main is the entry point for the Avatar PC application.
// It creates a window (WebKitGTK on Linux) and
// loads the 3D digital human rendering page.
package main

import (
	"embed"
	"fmt"
	"log/slog"
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
	setupLogging()
	slog.Info("Avatar PC starting...")

	// ── Load config ────────────────────────────────────────
	cfg, err := config.Load()
	if err != nil {
		slog.Warn(fmt.Sprintf("cfg.yml 加载失败 — 无法进行对话，数字人将使用默认响应 (error: %v)", err))
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
	slog.Info(fmt.Sprintf("main: %s", config.ProxyDesc(cfg.Proxy, cfg.ProxyDisabled)))

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
		slog.Error("Failed to create TTS engine", "error", err)
		os.Exit(1)
	}
	defer ttsEngine.Close()

	// Print TTS mode prominently.
	slog.Info("══════════════════════════════════════")
	if ttsMode == tts.ModeOnline {
		slog.Info("  TTS 语音合成: 在线模式 (阿里云百炼 Qwen-TTS)")
	} else {
		slog.Info("  TTS 语音合成: 离线模式 (本地 Matcha-TTS)")
	}
	slog.Info("══════════════════════════════════════")

	// ── Initialize audio player ──────────────────────────────
	player, err := audio.NewPlayer(ttsEngine.SampleRate())
	if err != nil {
		slog.Error("Failed to create audio player", "error", err)
		os.Exit(1)
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
		slog.Warn(fmt.Sprintf("ASR engine init failed (continuing without ASR): %v", err))
		asrEngine = nil
	} else {
		defer asrEngine.Close()
	}

	// Print ASR mode prominently.
	slog.Info("══════════════════════════════════════")
	if asrEngine == nil {
		slog.Info("  ASR 语音识别: 未启用 (初始化失败)")
	} else if asrMode == asr.ModeOnline {
		slog.Info("  ASR 语音识别: 在线模式 (阿里云百炼 Qwen-ASR)")
	} else {
		slog.Info("  ASR 语音识别: 离线模式 (本地 SenseVoiceSmall)")
	}
	slog.Info("══════════════════════════════════════")

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
		slog.Warn(fmt.Sprintf("KWS engine init failed (continuing without wake word): %v", err))
		kwsEngine = nil
	} else {
		defer kwsEngine.Close()
	}

	// ── Initialize microphone capture ────────────────────────
	capture, err := audio.NewCapture(audio.DefaultCaptureConfig())
	if err != nil {
		slog.Warn(fmt.Sprintf("microphone capture init failed (continuing without audio input): %v", err))
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
		slog.Info("LLM client configured (streaming enabled)")
	} else {
		slog.Info("LLM client NOT configured — set values in cfg.yml. Using fallback responses.")
	}

	// ── Create the renderer window (platform-specific) ──────
	r, err := renderer.New(webAssets, cfg.IsFBXEnabled())
	if err != nil {
		slog.Error("Failed to create renderer", "error", err)
		os.Exit(1)
	}
	defer r.Close()

	// ── Create the brain (state machine) ─────────────────────
	sm := brain.NewStateMachine(ttsEngine, player, asrEngine, kwsEngine, llmClient, capture, brain.Config{
		NoSpeechTimeout: cfg.NoSpeechTimeout(),
	})
	slog.Info(fmt.Sprintf("main: 多轮对话无语音超时 = %s（修改请改 cfg.yml 的 no_speech_timeout_sec）", cfg.NoSpeechTimeout()))
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
		slog.Info("Avatar PC shutting down...")
		// Send fade-out before closing.
		r.SendMessage(map[string]string{"cmd": "fade_out"})
		time.Sleep(1100 * time.Millisecond)
		r.Close()
	}()

	// Run the renderer's main loop (blocks until the window closes).
	r.Run()
}