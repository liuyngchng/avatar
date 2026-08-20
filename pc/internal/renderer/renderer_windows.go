//go:build windows

package renderer

import (
	"encoding/json"
	"io/fs"
	"log"
	"net"
	"net/http"
	"strconv"

	"github.com/jchv/go-webview2"
	"github.com/liuyngchng/avatar-pc/internal/brain"
)

type webviewRenderer struct {
	webview *webview2.WebView
	events  chan brain.Event
}

// newPlatformRenderer creates a Windows renderer using WebView2.
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

	r := &webviewRenderer{
		events: make(chan brain.Event, 16),
	}

	// WebView2 with transparent background.
	// Note: background transparency requires WebView2 Runtime 1.0.1054.31+
	// and setting the ICoreWebView2Controller2.DefaultBackgroundColor to
	// transparent (0, 0, 0, 0). This is done via the window.options.
	// We set the page HTML/CSS to transparent: body { background: transparent }.
	webview := webview2.NewWithOptions(webview2.WebViewOptions{
		Debug:     false,
		AutoFocus: true,
		WindowOptions: webview2.WindowOptions{
			Title:  "Avatar PC",
			Width:  1280,
			Height: 800,
		},
	})

	if webview == nil {
		listener.Close()
		return nil, err
	}

	r.webview = webview

	// Handle postMessage from JS (window.chrome.webview.postMessage).
	webview.MessageReceived(func(message string) {
		var ev brain.Event
		if err := json.Unmarshal([]byte(message), &ev); err != nil {
			log.Printf("renderer: bad message from JS: %v", err)
			return
		}
		select {
		case r.events <- ev:
		default:
			log.Printf("renderer: dropping event (channel full): %s", ev.Type)
		}
	})

	webview.Navigate(url)

	return r, nil
}

func (r *webviewRenderer) SendMessage(msg any) {
	data, err := json.Marshal(msg)
	if err != nil {
		log.Printf("renderer: marshal error: %v", err)
		return
	}
	js := "if(window.handleMessage)handleMessage(" + strconv.Quote(string(data)) + ")"
	r.webview.Eval(js)
}

func (r *webviewRenderer) Events() <-chan brain.Event {
	return r.events
}

func (r *webviewRenderer) Close() {
	r.webview.Destroy()
}