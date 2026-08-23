// Package config reads the Avatar Web configuration from cfg.yml.
package config

import (
	"fmt"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
)

// Config holds all application configuration.
type Config struct {
	LLM      LLMConfig    `yaml:"llm"`
	WakeWord string       `yaml:"wake_word"`
	ASR      ASRConfig    `yaml:"asr"`
	TTS      TTSConfig    `yaml:"tts"`
	Server   ServerConfig `yaml:"server"`
}

// LLMConfig holds the LLM API connection parameters.
type LLMConfig struct {
	BaseURL string `yaml:"base_url"`
	APIKey  string `yaml:"api_key"`
	Model   string `yaml:"model"`
}

// ASRConfig holds speech recognition configuration.
type ASRConfig struct {
	Mode    string `yaml:"mode"` // "offline" or "online"
	BaseURL string `yaml:"base_url"`
	APIKey  string `yaml:"api_key"`
	Model   string `yaml:"model"`
}

// TTSConfig holds speech synthesis configuration.
type TTSConfig struct {
	Mode    string `yaml:"mode"` // "offline" or "online"
	BaseURL string `yaml:"base_url"`
	APIKey  string `yaml:"api_key"`
	Model   string `yaml:"model"`
	Voice   string `yaml:"voice"`
}

// ServerConfig holds the HTTP server configuration.
type ServerConfig struct {
	Port      int    `yaml:"port"`
	StaticDir string `yaml:"static_dir"`
	// TLS certificate files. If both are set, the server serves HTTPS.
	CertFile string `yaml:"cert_file"`
	KeyFile  string `yaml:"key_file"`
}

// Load reads cfg.yml from standard locations.
func Load() (*Config, error) {
	path := findCfg()
	if path == "" {
		return nil, fmt.Errorf("config: cfg.yml not found")
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("config: read %s: %w", path, err)
	}

	cfg := &Config{
		// Defaults
		Server: ServerConfig{
			Port:      8080,
			StaticDir: "web",
		},
		ASR: ASRConfig{Mode: "offline"},
		TTS: TTSConfig{Mode: "offline"},
	}
	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("config: parse %s: %w", path, err)
	}

	return cfg, nil
}

// findCfg searches for cfg.yml in standard locations.
func findCfg() string {
	candidates := []string{
		"cfg.yml",
		"../cfg.yml",
		filepath.Join(filepath.Dir(os.Args[0]), "cfg.yml"),
	}
	for _, p := range candidates {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}