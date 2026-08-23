// Package llm provides an OpenAI-compatible LLM HTTP client with
// SSE streaming support.
package llm

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Config holds the LLM connection parameters.
type Config struct {
	// BaseURL is the API base URL (e.g. "https://api.openai.com/v1").
	BaseURL string
	// APIKey is the Bearer token.
	APIKey string
	// Model is the model name (e.g. "gpt-4o-mini", "qwen-turbo").
	Model string
	// SystemPrompt overrides the default system prompt.
	SystemPrompt string
	// Name is the character name used in the system prompt (default: "小然").
	Name string
}

// Message is a single chat message.
type Message struct {
	Role    string `json:"role"`    // "system", "user", "assistant"
	Content string `json:"content"` // message text
}

// ChatParams controls generation behavior.
type ChatParams struct {
	MaxTokens   int     `json:"max_tokens"`
	Temperature float64 `json:"temperature"`
	TopP        float64 `json:"top_p"`
}

// DefaultParams returns sensible defaults.
func DefaultParams() ChatParams {
	return ChatParams{
		MaxTokens:   512,
		Temperature: 0.7,
		TopP:        0.9,
	}
}

// Client is an OpenAI-compatible LLM HTTP client.
type Client struct {
	config  Config
	http    *http.Client
	system  string
}

// New creates a new LLM client.
func New(cfg Config) *Client {
	if cfg.BaseURL == "" {
		cfg.BaseURL = "https://api.openai.com/v1"
	}
	if cfg.Model == "" {
		cfg.Model = "gpt-4o-mini"
	}
	if cfg.Name == "" {
		cfg.Name = "小然"
	}

	return &Client{
		config: cfg,
		http: &http.Client{
			Timeout: 120 * time.Second,
			// No proxy (direct connection to the intranet LLM API).
			Transport: &http.Transport{
				Proxy: nil,
				// The intranet API uses a self-signed TLS certificate;
				// skip verification (same as `curl -k`).
				TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
			},
		},
		system: defaultSystemPrompt(cfg.Name),
	}
}

// Chat sends a non-streaming chat request and returns the full response.
func (c *Client) Chat(messages []Message, params ChatParams) (string, error) {
	body := c.buildBody(messages, params, false)
	respBody, err := c.doRequest(body)
	if err != nil {
		return "", err
	}
	defer respBody.Close()

	var result struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.NewDecoder(respBody).Decode(&result); err != nil {
		return "", fmt.Errorf("llm: failed to parse response: %w", err)
	}
	if len(result.Choices) == 0 {
		return "", fmt.Errorf("llm: no choices in response")
	}
	return result.Choices[0].Message.Content, nil
}

// ChatStream sends a streaming chat request and pushes chunks to the
// returned channel. The channel is closed when the response is complete
// or an error occurs.
func (c *Client) ChatStream(messages []Message, params ChatParams) (<-chan string, <-chan error) {
	chunkCh := make(chan string, 64)
	errCh := make(chan error, 1)

	go func() {
		defer close(chunkCh)
		defer close(errCh)

		body := c.buildBody(messages, params, true)
		respBody, err := c.doRequest(body)
		if err != nil {
			errCh <- err
			return
		}
		defer respBody.Close()

		scanner := bufio.NewScanner(respBody)
		// Increase buffer for long SSE lines.
		scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

		for scanner.Scan() {
			line := scanner.Text()
			if !strings.HasPrefix(line, "data: ") {
				continue
			}

			data := strings.TrimSpace(line[6:])
			if data == "[DONE]" {
				return
			}

			var sse struct {
				Choices []struct {
					Delta struct {
						Content          string `json:"content"`
						ReasoningContent string `json:"reasoning_content"`
					} `json:"delta"`
				} `json:"choices"`
			}
			if err := json.Unmarshal([]byte(data), &sse); err != nil {
				continue // skip malformed lines
			}

			if len(sse.Choices) > 0 {
				// Skip reasoning tokens (deepseek thinking), only collect actual content.
				if sse.Choices[0].Delta.Content != "" {
					chunkCh <- sse.Choices[0].Delta.Content
				}
				// Note: reasoning_content tokens are silently discarded.
			}
		}

		if err := scanner.Err(); err != nil {
			errCh <- fmt.Errorf("llm: SSE read error: %w", err)
		}
	}()

	return chunkCh, errCh
}

// IsConfigured returns true if the client has the minimum required config.
func (c *Client) IsConfigured() bool {
	return c.config.BaseURL != "" && c.config.APIKey != ""
}

// doRequest sends the JSON body to the chat completions endpoint and
// returns the response body reader.
func (c *Client) doRequest(body []byte) (io.ReadCloser, error) {
	url := strings.TrimRight(c.config.BaseURL, "/") + "/chat/completions"

	req, err := http.NewRequest("POST", url, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("llm: request error: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+c.config.APIKey)

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("llm: HTTP error: %w", err)
	}

	if resp.StatusCode != 200 {
		defer resp.Body.Close()
		errBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return nil, fmt.Errorf("llm: API error %d: %s", resp.StatusCode, string(errBody))
	}

	return resp.Body, nil
}

// buildBody constructs the JSON request body.
func (c *Client) buildBody(messages []Message, params ChatParams, stream bool) []byte {
	msgArray := make([]map[string]string, 0, len(messages)+1)

	// System prompt.
	sysPrompt := c.system
	if c.config.SystemPrompt != "" {
		sysPrompt = c.config.SystemPrompt
	}
	msgArray = append(msgArray, map[string]string{
		"role":    "system",
		"content": sysPrompt,
	})

	// Conversation messages.
	for _, msg := range messages {
		msgArray = append(msgArray, map[string]string{
			"role":    msg.Role,
			"content": msg.Content,
		})
	}

	reqBody := map[string]any{
		"model":       c.config.Model,
		"messages":    msgArray,
		"stream":      stream,
		"max_tokens":  params.MaxTokens,
		"temperature": params.Temperature,
		"top_p":       params.TopP,
	}

	b, _ := json.Marshal(reqBody)
	return b
}

// defaultSystemPrompt returns the system prompt used by the digital human.
// Matches the iOS/Android prompt.
func defaultSystemPrompt(name string) string {
	now := time.Now().Format("2006年1月2日 Monday")
	return "你是一个语音助手，名字叫「" + name + "」。用口语化的中文回复，自然友好、直接明了。" +
		"闲聊或简单问题控制在1-3句话（80字以内）；" +
		"知识类问题可以适当展开解释，但保持简洁，不超过150字。" +
		"围绕用户的问题回答，不要偏离话题。" +
		"当前日期是" + now + "（仅当需要判断时间时参考，不要主动报日期）。" +
		"这是一个多轮对话，记住之前聊过的话题，保持一致的语气。" +
		"训练数据中有的知识可以直接回答；确实不知道的事情，诚实说明即可。" +
		"回复时可以在开头用[emotion:表情]标签标注情绪，可选表情：neutral/happy/curious/surprised/shy/sleepy/sad。" +
		"例如：[emotion:happy]你好呀！今天天气真不错！"
}

// ParseEmotion extracts the emotion tag from the beginning of the response text.
// Returns the emotion and the cleaned text. If no tag is found, returns
// "neutral" and the original text.
func ParseEmotion(text string) (emotion string, cleanText string) {
	text = strings.TrimSpace(text)
	const prefix = "[emotion:"
	if strings.HasPrefix(text, prefix) {
		end := strings.Index(text, "]")
		if end > 0 {
			raw := text[len(prefix):end]
			cleanText = strings.TrimSpace(text[end+1:])
			switch raw {
			case "neutral", "happy", "curious", "surprised", "shy", "sleepy", "sad":
				return raw, cleanText
			default:
				// Unknown tag: still strip it, keep emotion neutral.
				return "neutral", cleanText
			}
		}
	}
	return "neutral", text
}

// ChatURL returns the full chat completions URL for the given config.
func (c *Client) ChatURL() string {
	return strings.TrimRight(c.config.BaseURL, "/") + "/chat/completions"
}