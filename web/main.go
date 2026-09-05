// Package main is the entry point for the Avatar Web server.
// It serves the 3D digital human frontend as static files and
// provides a WebSocket endpoint for real-time audio communication.
//
// HTTPS:
//
//	If cert.pem and key.pem exist in the working directory, the server
//	automatically serves HTTPS. Otherwise, plain HTTP.
//	Generate them with:  ./avatar-server -gen-cert
package main

import (
	"embed"
	"flag"
	"io/fs"
	"log/slog"
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
	slog.SetDefault(slog.New(newHumanHandler(os.Stderr, slog.LevelInfo, pkgDir)))

	genCert := flag.Bool("gen-cert", false, "Generate self-signed TLS certificate and exit")
	flag.Parse()

	// ── -gen-cert: generate certs, then exit ──────────────────
	if *genCert {
		ips := certgen.LocalIPs()
		slog.Info("generating_self_signed_certificate")
		for _, ip := range ips {
			slog.Info("cert_san_ip", "ip", ip.String())
		}
		hosts := []string{"localhost"}
		if err := certgen.Generate(defaultCertFile, defaultKeyFile, hosts, ips); err != nil {
			slog.Error("certificate_generation_failed", "error", err)
			os.Exit(1)
		}
		slog.Info("certificate_written_to", "path", defaultCertFile)
		slog.Info("private_key_written_to", "path", defaultKeyFile)
		slog.Info("restart_without_gen_cert_to_use_https")
		return
	}

	slog.Info("avatar_web_starting")

	// ── Load config ────────────────────────────────────────
	cfg, err := config.Load()
	if err != nil {
		slog.Warn("config_load_failed", "error", err)
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
	slog.Info("proxy_current_state", "desc", config.ProxyDesc(cfg.Proxy, cfg.ProxyDisabled))

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
		slog.Error("tts_engine_create_failed", "error", err)
		os.Exit(1)
	}
	defer ttsEngine.Close()

	// Print TTS mode prominently.
	slog.Info("tts_mode_banner_top")
	if ttsMode == tts.ModeOnline {
		slog.Info("tts_mode_online_dashscope_qwen")
	} else {
		slog.Info("tts_mode_offline_matcha")
	}
	slog.Info("tts_mode_banner_bottom")

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
		slog.Warn("asr_engine_init_failed_continuing_without", "error", err)
		asrEngine = nil
	} else {
		defer asrEngine.Close()
	}

	// Print ASR mode prominently.
	slog.Info("asr_mode_banner_top")
	if asrEngine == nil {
		slog.Info("asr_mode_disabled_init_failed")
	} else if asrMode == asr.ModeOnline {
		slog.Info("asr_mode_online_dashscope_qwen")
	} else {
		slog.Info("asr_mode_offline_sensevoice")
	}
	slog.Info("asr_mode_banner_bottom")

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
		slog.Warn("kws_engine_init_failed_continuing_without", "error", err)
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
	// Always log the effective LLM config so the user can verify.
	llmBaseURL := cfg.LLM.BaseURL
	llmModel := cfg.LLM.Model
	llmHasBaseURL := llmBaseURL != ""
	llmHasAPIKey := llmAPIKey != ""
	slog.Info("llm_config_base_url", "set", llmHasBaseURL, "value", llmBaseURL)
	slog.Info("llm_config_api_key", "set", llmHasAPIKey)
	slog.Info("llm_config_model", "model", llmModel)

	llmClient := llm.New(llm.Config{
		BaseURL:   llmBaseURL,
		APIKey:    llmAPIKey,
		Model:     llmModel,
		Name:      cfg.LLM.Name,
		ProxyFunc: config.ProxyFunc(cfg.Proxy, cfg.ProxyDisabled),
	})

	if llmClient.IsConfigured() {
		slog.Info("llm_client_configured_streaming")
	} else {
		if !llmHasBaseURL {
			slog.Warn("llm_client_missing_base_url")
		}
		if !llmHasAPIKey {
			slog.Warn("llm_client_missing_api_key")
		}
	}

	// ── Create the brain (state machine) ─────────────────────
	sm := brain.NewStateMachine(ttsEngine, asrEngine, kwsEngine, llmClient, brain.Config{
		NoSpeechTimeout: cfg.NoSpeechTimeout(),
	})
	slog.Info("no_speech_timeout_configured", "timeout", cfg.NoSpeechTimeout())
	defer sm.Stop() // must run before engine Close()s to avoid use-after-free crashes

	// Start the FSM loop.
	go sm.Run()

	// ── HTTP routes ────────────────────────────────────────
	mux := http.NewServeMux()

	// WebSocket endpoint: /ws
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		_, err := transport.NewSession(w, r, sm)
		if err != nil {
			slog.Warn("websocket_upgrade_failed", "error", err)
			http.Error(w, "WebSocket upgrade failed", http.StatusBadRequest)
			return
		}
	})

	// Static file server for the 3D frontend.
	webFS, err := fs.Sub(webAssets, "web")
	if err != nil {
		slog.Error("web_sub_filesystem_create_failed", "error", err)
		os.Exit(1)
	}
	fsHandler := http.FileServer(http.FS(webFS))
	mux.Handle("/", fsHandler)

	addr := ":" + strconv.Itoa(cfg.Server.Port)
	server := &http.Server{
		Addr:    addr,
		Handler: mux,
		// Route net/http's own logs (e.g. "TLS handshake error from ...")
		// through slog.Warn instead of slog.Info. These are routine — the
		// browser rejects the self-signed cert on the first HTTPS attempt —
		// so INFO would only add noise; WARN keeps them visible if ever
		// needed for debugging.
		ErrorLog: slog.NewLogLogger(slog.Default().Handler(), slog.LevelWarn),
	}

	// ── Handle SIGINT/SIGTERM ──────────────────────────────
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		slog.Info("avatar_web_shutting_down")
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
		ips := certgen.LocalIPs()
		slog.Info("listening_on_https_localhost", "addr", "localhost"+addr)
		for _, ip := range ips {
			slog.Info("listening_on_https_ip", "addr", ip.String()+addr)
		}
		slog.Info("open_https_in_browser", "url", "https://localhost"+addr)
		if err := server.ListenAndServeTLS(certFile, keyFile); err != http.ErrServerClosed {
			slog.Error("server_listen_tls_error", "error", err)
			os.Exit(1)
		}
	} else {
		ips := certgen.LocalIPs()
		slog.Info("listening_on_http_localhost", "addr", "localhost"+addr)
		for _, ip := range ips {
			slog.Info("listening_on_http_ip", "addr", ip.String()+addr)
		}
		slog.Info("open_http_in_browser", "url", "http://localhost"+addr)
		slog.Info("tip_run_gen_cert_for_https")
		if err := server.ListenAndServe(); err != http.ErrServerClosed {
			slog.Error("server_listen_error", "error", err)
			os.Exit(1)
		}
	}

	slog.Info("avatar_web_stopped")
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
