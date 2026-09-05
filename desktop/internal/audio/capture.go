// Package audio provides PCM audio capture and playback.
//
// This file implements microphone capture via ALSA (Linux) using CGo.
// The capture is 16kHz mono 16-bit PCM, converted to float32 samples
// normalized in [-1, 1].
package audio

// #cgo LDFLAGS: -lasound
// #include <alsa/asoundlib.h>
// #include <stdlib.h>
import "C"

import (
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"unsafe"
)

// CaptureConfig defines the capture parameters.
type CaptureConfig struct {
	// SampleRate is the audio sample rate in Hz (default 16000).
	SampleRate int
	// Channels is the number of channels (default 1, mono).
	Channels int
	// BufferMs is the buffer duration in milliseconds (default 100).
	BufferMs int
	// Device is the ALSA device name (default "default").
	Device string
}

// DefaultCaptureConfig returns a sensible default configuration.
func DefaultCaptureConfig() CaptureConfig {
	return CaptureConfig{
		SampleRate: 16000,
		Channels:   1,
		BufferMs:   100,
		Device:     "default",
	}
}

// Capture provides microphone audio capture via ALSA.
type Capture struct {
	mu       sync.Mutex
	handle   *C.snd_pcm_t
	running  atomic.Bool
	sampleCh chan []float32
	done     chan struct{}

	config CaptureConfig
}

// NewCapture opens an ALSA capture device.
func NewCapture(cfg CaptureConfig) (*Capture, error) {
	if cfg.SampleRate <= 0 {
		cfg.SampleRate = 16000
	}
	if cfg.Channels <= 0 {
		cfg.Channels = 1
	}
	if cfg.BufferMs <= 0 {
		cfg.BufferMs = 100
	}
	if cfg.Device == "" {
		cfg.Device = "default"
	}

	c := &Capture{
		config:   cfg,
		sampleCh: make(chan []float32, 8),
		done:     make(chan struct{}),
	}

	deviceName := C.CString(cfg.Device)
	defer C.free(unsafe.Pointer(deviceName))

	var handle *C.snd_pcm_t
	ret := C.snd_pcm_open(&handle, deviceName, C.SND_PCM_STREAM_CAPTURE, 0)
	if ret < 0 {
		return nil, fmt.Errorf("audio: failed to open ALSA device %q: %s",
			cfg.Device, alsaStrError(ret))
	}
	c.handle = handle

	// Configure hardware parameters.
	if err := c.setupHWParams(); err != nil {
		C.snd_pcm_close(handle)
		return nil, err
	}

	slog.Info("audio_capture_opened", "device", cfg.Device, "rate", cfg.SampleRate, "channels", cfg.Channels, "bufferMs", cfg.BufferMs)
	return c, nil
}

func (c *Capture) setupHWParams() error {
	var hwparams *C.snd_pcm_hw_params_t
	C.snd_pcm_hw_params_malloc(&hwparams)
	defer C.snd_pcm_hw_params_free(hwparams)

	ret := C.snd_pcm_hw_params_any(c.handle, hwparams)
	if ret < 0 {
		return fmt.Errorf("audio: hw_params_any: %s", alsaStrError(ret))
	}

	ret = C.snd_pcm_hw_params_set_access(c.handle, hwparams, C.SND_PCM_ACCESS_RW_INTERLEAVED)
	if ret < 0 {
		return fmt.Errorf("audio: set_access: %s", alsaStrError(ret))
	}

	ret = C.snd_pcm_hw_params_set_format(c.handle, hwparams, C.SND_PCM_FORMAT_S16_LE)
	if ret < 0 {
		return fmt.Errorf("audio: set_format: %s", alsaStrError(ret))
	}

	rate := C.uint(c.config.SampleRate)
	ret = C.snd_pcm_hw_params_set_rate_near(c.handle, hwparams, &rate, nil)
	if ret < 0 {
		return fmt.Errorf("audio: set_rate: %s", alsaStrError(ret))
	}

	ret = C.snd_pcm_hw_params_set_channels(c.handle, hwparams, C.uint(c.config.Channels))
	if ret < 0 {
		return fmt.Errorf("audio: set_channels: %s", alsaStrError(ret))
	}

	// Set buffer size based on bufferMs.
	bufferSize := C.snd_pcm_uframes_t(c.config.SampleRate * c.config.BufferMs / 1000)
	ret = C.snd_pcm_hw_params_set_buffer_size_near(c.handle, hwparams, &bufferSize)
	if ret < 0 {
		return fmt.Errorf("audio: set_buffer_size: %s", alsaStrError(ret))
	}

	ret = C.snd_pcm_hw_params(c.handle, hwparams)
	if ret < 0 {
		return fmt.Errorf("audio: hw_params: %s", alsaStrError(ret))
	}

	return nil
}

// Start begins capturing audio. Samples are sent to the returned channel
// as float32 slices normalized in [-1, 1].
// Call Stop to end capture and close the channel.
func (c *Capture) Start() (<-chan []float32, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.running.Load() {
		return c.sampleCh, nil
	}

	if c.handle == nil {
		return nil, fmt.Errorf("audio: capture not initialized")
	}

	c.running.Store(true)

	// Re-open the done channel if it was closed by a previous Stop.
	select {
	case <-c.done:
		c.done = make(chan struct{})
		c.sampleCh = make(chan []float32, 8)
	default:
	}

	go c.loop()

	return c.sampleCh, nil
}

// loop is the capture goroutine.
func (c *Capture) loop() {
	defer close(c.sampleCh)

	// Calculate frames per buffer.
	framesPerBuffer := c.config.SampleRate * c.config.BufferMs / 1000
	buf := make([]int16, framesPerBuffer)

	for c.running.Load() {
		n := C.snd_pcm_readi(c.handle, unsafe.Pointer(&buf[0]), C.snd_pcm_uframes_t(framesPerBuffer))
		if n < 0 {
			// xrun or error — try to recover.
			rec := C.snd_pcm_recover(c.handle, C.int(n), 1)
			if rec < 0 {
				slog.Warn("audio_capture_error", "error", alsaStrError(rec))
				return
			}
			continue
		}

		if n > 0 {
			// Convert int16 samples to float32, normalized to [-1, 1].
			samples := make([]float32, n)
			for i := 0; i < int(n); i++ {
				samples[i] = float32(buf[i]) / 32768.0
			}
			select {
			case c.sampleCh <- samples:
			case <-c.done:
				return
			}
		}
	}
}

// Stop ends capture and releases the ALSA device.
func (c *Capture) Stop() {
	c.mu.Lock()
	defer c.mu.Unlock()

	if !c.running.Load() {
		return
	}

	c.running.Store(false)
	close(c.done)

	// Drain the channel.
	for range c.sampleCh {
	}
}

// Close releases the ALSA device permanently.
func (c *Capture) Close() {
	c.Stop()

	c.mu.Lock()
	defer c.mu.Unlock()

	if c.handle != nil {
		C.snd_pcm_close(c.handle)
		c.handle = nil
		slog.Info("audio_capture_closed")
	}
}

// IsRunning returns true if capture is active.
func (c *Capture) IsRunning() bool {
	return c.running.Load()
}

// alsaStrError converts an ALSA error code to a human-readable string.
func alsaStrError(err C.int) string {
	return C.GoString(C.snd_strerror(err))
}