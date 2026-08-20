// Package config reads the Avatar PC configuration from cfg.yml.
package config

import (
	"fmt"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
)

// Config holds all application configuration.
type Config struct {
	LLM LLMConfig `yaml:"llm"`
}

// LLMConfig holds the LLM API connection parameters.
type LLMConfig struct {
	BaseURL string `yaml:"base_url"`
	APIKey  string `yaml:"api_key"`
	Model   string `yaml:"model"`
}

// Load reads cfg.yml from the working directory or alongside the binary.
func Load() (*Config, error) {
	path := findCfg()
	if path == "" {
		return nil, fmt.Errorf("config: cfg.yml not found")
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("config: read %s: %w", path, err)
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("config: parse %s: %w", path, err)
	}

	return &cfg, nil
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