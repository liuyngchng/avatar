//go:build linux

package renderer

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"

	"github.com/liuyngchng/avatar-pc/internal/brain"
)

// gtkRenderer is a Linux renderer backed by a separate GTK3 + WebKit2GTK
// process ("avatar-ui"). Keeping WebKit in its own process avoids the signal
// conflict between the Go runtime and WebKit's JavaScriptCore
// (JSC_SIGNAL_FOR_GC), which is unsolvable in a single process.
//
// The two processes communicate over stdin/stdout pipes, one JSON object per
// line. See PROPOSAL_GTK_IPC.md and cmd/avatar-ui/main.c for the protocol.
type gtkRenderer struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	events chan brain.Event
	done   chan struct{}

	mu      sync.Mutex
	closed  bool
	waitErr error
}

var _ Renderer = (*gtkRenderer)(nil)

// uiBinaryName is the name of the C UI executable that must live alongside
// the Go binary.
const uiBinaryName = "avatar-ui"

// findUIBinary locates the avatar-ui executable. It searches, in order:
//  1. the directory of the currently running Go executable, and
//  2. the current working directory.
func findUIBinary() (string, error) {
	exe, err := os.Executable()
	if err == nil {
		candidate := filepath.Join(filepath.Dir(exe), uiBinaryName)
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		}
	}
	if _, err := os.Stat(uiBinaryName); err == nil {
		return uiBinaryName, nil
	}
	return "", errors.New("avatar-ui binary not found; build it with `make avatar-ui` or `make build`")
}

// newPlatformRenderer creates a Linux renderer using a child GTK process.
func newPlatformRenderer(webFS fs.FS) (Renderer, error) {
	// Serve the embedded web assets on a random local port.
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	port := listener.Addr().(*net.TCPAddr).Port

	srv := &http.Server{Handler: http.FileServer(http.FS(webFS))}
	go srv.Serve(listener)

	url := "http://127.0.0.1:" + strconv.Itoa(port) + "/index.html"
	log.Printf("renderer: serving at %s", url)

	// Locate and start the C UI child process.
	uiBin, err := findUIBinary()
	if err != nil {
		listener.Close()
		return nil, err
	}

	cmd := exec.Command(uiBin, url)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		listener.Close()
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		listener.Close()
		return nil, err
	}
	// Forward stderr to our own stderr so GTK/WebKit diagnostics are visible.
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		listener.Close()
		return nil, err
	}

	r := &gtkRenderer{
		cmd:    cmd,
		stdin:  stdin,
		events: make(chan brain.Event, 16),
		done:   make(chan struct{}),
	}

	// Read events from the C process's stdout and forward them to the events
	// channel. Each line is a JSON object produced by the JS→Go bridge.
	go func() {
		scanner := bufio.NewScanner(stdout)
		// Events are small; bump the buffer just in case of long payloads.
		scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line == "" {
				continue
			}
			var ev brain.Event
			if err := json.Unmarshal([]byte(line), &ev); err != nil {
				log.Printf("renderer: bad message from UI: %v (raw: %s)", err, line)
				continue
			}
			select {
			case r.events <- ev:
			default:
				log.Printf("renderer: dropping event (channel full): %s", ev.Type)
			}
		}
		// stdout closed (UI exited) — unblock Run() if it's still waiting.
		close(r.done)
	}()

	// Reap the child process in the background.
	go func() {
		r.waitErr = cmd.Wait()
		close(r.done)
	}()

	return r, nil
}

// SendMessage marshals a message and evaluates JS in the UI process.
func (r *gtkRenderer) SendMessage(msg any) {
	data, err := json.Marshal(msg)
	if err != nil {
		log.Printf("renderer: marshal error: %v", err)
		return
	}
	js := "if(window.handleMessage)handleMessage(" + strconv.Quote(string(data)) + ")"
	cmd := map[string]string{"cmd": "eval", "js": js}
	r.writeCommand(cmd)
}

// writeCommand serializes a command to the UI process's stdin.
func (r *gtkRenderer) writeCommand(cmd any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed || r.stdin == nil {
		return
	}
	data, err := json.Marshal(cmd)
	if err != nil {
		log.Printf("renderer: marshal error: %v", err)
		return
	}
	if _, err := r.stdin.Write(append(data, '\n')); err != nil {
		log.Printf("renderer: write to UI failed: %v", err)
	}
}

// Events returns the channel of user events from JS.
func (r *gtkRenderer) Events() <-chan brain.Event {
	return r.events
}

// Run blocks until the UI process exits.
func (r *gtkRenderer) Run() {
	<-r.done
}

// Close quits the UI process.
func (r *gtkRenderer) Close() {
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return
	}
	r.closed = true
	stdin := r.stdin
	r.mu.Unlock()

	if stdin != nil {
		// Ask the UI to quit gracefully.
		_, _ = io.WriteString(stdin, "{\"cmd\":\"quit\"}\n")
		_ = stdin.Close()
	}
}
