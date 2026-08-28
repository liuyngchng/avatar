// Package main is the entry point for the Avatar Web server.
// It serves the 3D digital human frontend as static files and
// provides a WebSocket endpoint for real-time audio communication.
//
// HTTPS:
//   If cert.pem and key.pem exist in the working directory, the server
//   automatically serves HTTPS. Otherwise, plain HTTP.
//   Generate them with:  ./avatar-server -gen-cert
package main

import (
	"embed"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"

	"github.com/liuyngchng/avatar-web/internal/asr"
	"github.com/liuyngchng/avatar-web/internal/brain"
	"github.com/liuyngchng/avatar-web/internal/certgen"
	"github.com/liuyngchng/avatar-web/internal/config"
	"github.com/liuyngchng/avatar-web/internal/kws"
	"github.com/liuyngchng/avatar-web/internal/llm"
	"github.com/liuyngchng/avatar-web/internal/transport"
	"github.com/liuyngchng/avatar-web/internal/tts"
)

//go:embed web
var webAssets embed.FS

const (
	defaultCertFile = "cert.pem"
	defaultKeyFile  = "key.pem"
)

func main() {
	log.SetFlags(log.Ltime | log.Lshortfile)

	genCert := flag.Bool("gen-cert", false, "Generate self-signed TLS certificate and exit")
	flag.Parse()

	// ── -gen-cert: generate certs, then exit ──────────────────
	if *genCert {
		ips := certgen.LocalIPs()
		fmt.Printf("Generating self-signed certificate for these local IPs:\n")
		for _, ip := range ips {
			fmt.Printf("  %s\n", ip)
		}
		hosts := []string{"localhost"}
		if err := certgen.Generate(defaultCertFile, defaultKeyFile, hosts, ips); err != nil {
			log.Fatalf("Failed to generate certificate: %v", err)
		}
		fmt.Printf("\nCertificate written to: %s\n", defaultCertFile)
		fmt.Printf("Private key written to:  %s\n", defaultKeyFile)
		fmt.Println("\nRestart the server without -gen-cert to use HTTPS.")
		return
	}

	log.Println("Avatar Web starting...")

	// ── Load config ────────────────────────────────────────
	cfg, err := config.Load()
	if err != nil {
		log.Printf("Warning: failed to load config: %v (using env vars as fallback)", err)
		cfg = &config.Config{
			LLM: config.LLMConfig{
				BaseURL: os.Getenv("AVATAR_LLM_BASE_URL"),
				APIKey:  os.Getenv("AVATAR_LLM_API_KEY"),
				Model:   os.Getenv("AVATAR_LLM_MODEL"),
				Name:    "小然",
			},
			ASR: config.ASRConfig{Mode: "offline"},
			TTS: config.TTSConfig{Mode: "offline"},
			Server: config.ServerConfig{
				Port:      8080,
				StaticDir: "web",
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
	if v := os.Getenv("AVATAR_SERVER_PORT"); v != "" {
		if p, err := strconv.Atoi(v); err == nil {
			cfg.Server.Port = p
		}
	}
	// Default character name (used in system prompt and wake word).
	if cfg.LLM.Name == "" {
		cfg.LLM.Name = "小然"
	}

	// Print proxy state so the user knows at a glance.
	log.Printf("main: %s", config.ProxyDesc(cfg.Proxy, cfg.ProxyDisabled))

	// ── Initialize TTS engine ────────────────────────────────
	ttsDir := tts.ModelsDir()
	ttsMode := tts.Mode(cfg.TTS.Mode)
	// TTS API key: use tts.api_key if set, otherwise fall back to top-level api_key.
	ttsAPIKey := cfg.APIKey
	ttsEngine, err := tts.New(ttsMode, tts.ModelPaths{
		AcousticModel: filepath.Join(ttsDir, "model.onnx"),
		Vocoder:       filepath.Join(ttsDir, "vocos.onnx"),
		Tokens:        filepath.Join(ttsDir, "tokens.txt"),
		Lexicon:       filepath.Join(ttsDir, "lexicon.txt"),
	}, cfg.TTS.URL, cfg.TTS.Model, cfg.TTS.Voice, ttsAPIKey, cfg.TTS.Format, cfg.TTS.SampleRate, config.ProxyFunc(cfg.Proxy, cfg.ProxyDisabled))
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

	// ── Initialize ASR engine ────────────────────────────────
	asrDir := asr.ModelsDir()
	asrMode := asr.Mode(cfg.ASR.Mode)
	// ASR API key: use asr.api_key if set, otherwise fall back to top-level api_key.
	asrAPIKey := cfg.APIKey
	var asrEngine *asr.Engine
	asrEngine, err = asr.New(asrMode, asr.ModelPaths{
		Model:  filepath.Join(asrDir, "model.int8.onnx"),
		Tokens: filepath.Join(asrDir, "tokens.txt"),
	}, cfg.ASR.URL, cfg.ASR.Model, asrAPIKey, cfg.ASR.Format, cfg.ASR.SampleRate, config.ProxyFunc(cfg.Proxy, cfg.ProxyDisabled))
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

	// ── Initialize KWS engine ────────────────────────────────
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

	// ── Create the brain (state machine) ─────────────────────
	sm := brain.NewStateMachine(ttsEngine, asrEngine, kwsEngine, llmClient, brain.Config{
		NoSpeechTimeout: cfg.NoSpeechTimeout(),
	})
	log.Printf("main: 多轮对话无语音超时 = %s (修改请改 cfg.yml 的 no_speech_timeout_sec)", cfg.NoSpeechTimeout())
	defer sm.Stop() // must run before engine Close()s to avoid use-after-free crashes

	// Start the FSM loop.
	go sm.Run()

	// ── HTTP routes ────────────────────────────────────────
	mux := http.NewServeMux()

	// WebSocket endpoint: /ws
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		_, err := transport.NewSession(w, r, sm)
		if err != nil {
			log.Printf("WebSocket upgrade failed: %v", err)
			http.Error(w, "WebSocket upgrade failed", http.StatusBadRequest)
			return
		}
	})

	// Static file server for the 3D frontend.
	webFS, err := fs.Sub(webAssets, "web")
	if err != nil {
		log.Fatalf("Failed to create web sub-filesystem: %v", err)
	}
	fsHandler := http.FileServer(http.FS(webFS))
	mux.Handle("/", fsHandler)

	addr := ":" + strconv.Itoa(cfg.Server.Port)
	server := &http.Server{
		Addr:    addr,
		Handler: mux,
	}

	// ── Handle SIGINT/SIGTERM ──────────────────────────────
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Println("Avatar Web shutting down...")
		server.Close()
	}()

	// ── Determine whether to use HTTPS ──────────────────────
	certFile := cfg.Server.CertFile
	keyFile := cfg.Server.KeyFile
	if certFile == "" {
		certFile = defaultCertFile
	}
	if keyFile == "" {
		keyFile = defaultKeyFile
	}

	useTLS := fileExists(certFile) && fileExists(keyFile)

	if useTLS {
		log.Printf("Avatar Web listening on https://localhost%s", addr)
		log.Printf("Open https://localhost%s in your browser", addr)
		if err := server.ListenAndServeTLS(certFile, keyFile); err != http.ErrServerClosed {
			log.Fatalf("Server error: %v", err)
		}
	} else {
		log.Printf("Avatar Web listening on http://localhost%s", addr)
		log.Printf("Open http://localhost%s in your browser", addr)
		log.Printf("(Tip: run with -gen-cert to enable HTTPS for microphone access from other devices)")
		if err := server.ListenAndServe(); err != http.ErrServerClosed {
			log.Fatalf("Server error: %v", err)
		}
	}

	log.Println("Avatar Web stopped.")
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
