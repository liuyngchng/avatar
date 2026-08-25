// Package config reads the Avatar PC configuration from cfg.yml.
package config

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// Config holds all application configuration.
type Config struct {
	LLM       LLMConfig `yaml:"llm"`
	WakeWord  string    `yaml:"wake_word"`
	EnableFBX *bool     `yaml:"enable_fbx"` // nil = not set, defaults to true
}

// LLMConfig holds the LLM API connection parameters.
type LLMConfig struct {
	BaseURL string `yaml:"base_url"`
	APIKey  string `yaml:"api_key"`
	Model   string `yaml:"model"`
	Name    string `yaml:"name"` // character name, defaults to "小冉"
}

// Load reads cfg.yml from the current working directory only.
// Returns an error if the file is not found or cannot be parsed.
func Load() (*Config, error) {
	const path = "cfg.yml"

	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("config: %s not found in current directory: %w", path, err)
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("config: parse %s: %w", path, err)
	}

	return &cfg, nil
}

// IsFBXEnabled returns true if FBX animation should be loaded.
// Defaults to true when the config key is not set.
func (c *Config) IsFBXEnabled() bool {
	if c.EnableFBX == nil {
		return true
	}
	return *c.EnableFBX
}