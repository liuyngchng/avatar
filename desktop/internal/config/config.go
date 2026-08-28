// Package config reads the Avatar PC configuration from cfg.yml.
package config

import (
	"fmt"
	"net/http"
	"net/url"
	"os"
	"time"

	"gopkg.in/yaml.v3"
)

// Config holds all application configuration.
type Config struct {
	LLM           LLMConfig    `yaml:"llm"`
	ASR           ASRConfig    `yaml:"asr"`
	TTS           TTSConfig    `yaml:"tts"`
	APIKey        string       `yaml:"api_key"`
	Proxy         string       `yaml:"proxy"`
	ProxyDisabled bool         `yaml:"proxy_disabled"`
	WakeWord           string       `yaml:"wake_word"`
	EnableFBX          *bool        `yaml:"enable_fbx"`            // nil = not set, defaults to true
	NoSpeechTimeoutSec *int         `yaml:"no_speech_timeout_sec"` // nil = not set, defaults to 5s
}

// LLMConfig holds the LLM API connection parameters.
type LLMConfig struct {
	BaseURL string `yaml:"base_url"`
	APIKey  string `yaml:"api_key"`
	Model   string `yaml:"model"`
	Name    string `yaml:"name"` // character name, defaults to "小然"
}

// ASRConfig holds speech recognition configuration.
// Mode is "offline" (local sherpa-onnx) or "online" (DashScope WebSocket API).
type ASRConfig struct {
	Mode       string `yaml:"mode"` // "offline" or "online"
	URL        string `yaml:"url"`
	Model      string `yaml:"model"`
	Format     string `yaml:"format"`
	SampleRate int    `yaml:"sample_rate"`
}

// TTSConfig holds text-to-speech configuration.
// Mode is "offline" (local sherpa-onnx) or "online" (DashScope WebSocket API).
type TTSConfig struct {
	Mode       string `yaml:"mode"` // "offline" or "online"
	URL        string `yaml:"url"`
	Model      string `yaml:"model"`
	Voice      string `yaml:"voice"`
	Format     string `yaml:"format"`
	SampleRate int    `yaml:"sample_rate"`
}

// Load reads cfg.yml from the current working directory only.
// Returns an error if the file is not found or cannot be parsed.
func Load() (*Config, error) {
	const path = "cfg.yml"

	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("config: %s not found in current directory: %w", path, err)
	}

	cfg := &Config{
		ASR: ASRConfig{Mode: "offline"},
		TTS: TTSConfig{Mode: "offline"},
	}
	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("config: parse %s: %w", path, err)
	}

	return cfg, nil
}

// IsFBXEnabled returns true if FBX animation should be loaded.
// Defaults to true when the config key is not set.
func (c *Config) IsFBXEnabled() bool {
	if c.EnableFBX == nil {
		return true
	}
	return *c.EnableFBX
}

// NoSpeechTimeout returns how long the multi-turn conversation waits for the
// user to start speaking after wake-up or after the previous turn ends before
// automatically closing the dialogue (so the user must re-wake to talk again).
// Defaults to 5 seconds when the config key is not set or is non-positive.
func (c *Config) NoSpeechTimeout() time.Duration {
	if c.NoSpeechTimeoutSec == nil || *c.NoSpeechTimeoutSec <= 0 {
		return 5 * time.Second
	}
	return time.Duration(*c.NoSpeechTimeoutSec) * time.Second
}

// ProxyFunc returns an http.Proxy function that respects the following
// priority, suitable for http.Transport and gorilla/websocket Dialer:
//
//  1. proxy_disabled: true — force direct connection, ignore env vars and cfg.
//  2. cfgProxy (cfg.yml proxy field) — if set, always use this proxy.
//  3. Environment variables (HTTPS_PROXY / HTTP_PROXY / NO_PROXY) —
//     standard Go ProxyFromEnvironment.
//  4. Direct connection — no proxy.
func ProxyFunc(cfgProxy string, disabled bool) func(*http.Request) (*url.URL, error) {
	if disabled {
		return func(*http.Request) (*url.URL, error) { return nil, nil }
	}
	if cfgProxy != "" {
		u, err := url.Parse(cfgProxy)
		if err == nil {
			return http.ProxyURL(u)
		}
	}
	return http.ProxyFromEnvironment
}

// ProxyDesc returns a human-readable description of the proxy state.
// Log this at startup so the user knows whether the app is using a proxy.
func ProxyDesc(cfgProxy string, disabled bool) string {
	if disabled {
		return "代理: 已强制关闭 (proxy_disabled=true), 直连"
	}
	if cfgProxy != "" {
		return fmt.Sprintf("代理: %s (cfg.yml proxy)", cfgProxy)
	}
	env := os.Getenv("HTTPS_PROXY")
	if env == "" {
		env = os.Getenv("HTTP_PROXY")
	}
	if env != "" {
		return fmt.Sprintf("代理: %s (环境变量)", env)
	}
	return "代理: 未配置, 直连"
}
