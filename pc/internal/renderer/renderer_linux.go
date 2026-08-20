//go:build linux

package renderer

/*
#cgo pkg-config: gtk+-3.0 webkit2gtk-4.1
#cgo CFLAGS: -Wno-deprecated-declarations
#include <stdlib.h>
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

// ── Thread-safe JS evaluation ──────────────────────────────
// scheduleEval can be called from any goroutine. It queues a
// webkit_web_view_evaluate_javascript() call on the GTK main thread.

typedef struct {
	WebKitWebView *webview;
	char *js;
} goEvalData;

static gboolean doEvalJS(gpointer userdata) {
	goEvalData *d = (goEvalData *)userdata;
	webkit_web_view_evaluate_javascript(d->webview, d->js, -1, NULL, NULL, NULL, NULL, NULL);
	g_free(d->js);
	g_free(d);
	return G_SOURCE_REMOVE;
}

static void scheduleEval(WebKitWebView *webview, const char *js) {
	goEvalData *d = g_new(goEvalData, 1);
	d->webview = webview;
	d->js = g_strdup(js);
	g_idle_add(doEvalJS, d);
}

// ── Forward declarations for exported Go callbacks ─────────
extern void go_message_received_cb(WebKitUserContentManager *, WebKitJavascriptResult *, gpointer);
extern void go_window_destroy_cb(GtkWidget *, gpointer);

// g_signal_connect is a macro in GLib; use the underlying function directly.
static gulong c_signal_connect(gpointer instance, const gchar *signal, GCallback cb, gpointer data) {
	return g_signal_connect_data(instance, signal, cb, data, NULL, 0);
}
*/
import "C"

import (
	"encoding/json"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"sync"
	"unsafe"

	"github.com/liuyngchng/avatar-pc/internal/brain"
)

// ── Global renderer instance for C callbacks ────────────────
var (
	activeRenderer *gtkRenderer
	rendererMu     sync.Mutex
)

// gtkRenderer is a Linux renderer backed by GTK3 + WebKit2GTK.
// It creates an undecorated, transparent window showing only the WebGL avatar.
type gtkRenderer struct {
	webview *C.WebKitWebView
	window  *C.GtkWidget
	events  chan brain.Event
	done    chan struct{}
}

var _ Renderer = (*gtkRenderer)(nil)

// newPlatformRenderer creates a Linux renderer using WebKitGTK.
func newPlatformRenderer(webFS fs.FS) (Renderer, error) {
	// JSC (WebKit's JavaScript engine) uses SIGUSR1 for garbage collection
	// by default, but Go's runtime also uses SIGUSR1. This causes a SIGABRT.
	// Tell JSC to use a different signal.
	_ = os.Setenv("JSC_SIGNAL_FOR_GC", "SIGUSR2")
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

	// GTK must be initialized on the main thread (this runs in main()).
	C.gtk_init(nil, nil)

	r := &gtkRenderer{
		events: make(chan brain.Event, 16),
		done:   make(chan struct{}),
	}

	rendererMu.Lock()
	activeRenderer = r
	rendererMu.Unlock()

	// ── Window: undecorated, transparent, portrait ──────────
	window := C.gtk_window_new(C.GTK_WINDOW_TOPLEVEL)
	C.gtk_window_set_title((*C.GtkWindow)(unsafe.Pointer(window)), C.CString("Avatar PC"))
	C.gtk_window_set_decorated((*C.GtkWindow)(unsafe.Pointer(window)), C.FALSE) // no title bar
	C.gtk_window_set_default_size((*C.GtkWindow)(unsafe.Pointer(window)), 480, 720)
	C.gtk_window_set_resizable((*C.GtkWindow)(unsafe.Pointer(window)), C.FALSE)
	C.gtk_window_set_keep_above((*C.GtkWindow)(unsafe.Pointer(window)), C.TRUE) // float on top

	// Enable RGBA visual so the window background can be transparent.
	screen := C.gtk_widget_get_screen(window)
	visual := C.gdk_screen_get_rgba_visual(screen)
	if visual != nil {
		C.gtk_widget_set_visual(window, visual)
	}

	r.window = window

	// ── WebView ─────────────────────────────────────────────
	webview := C.webkit_web_view_new()
	r.webview = (*C.WebKitWebView)(unsafe.Pointer(webview))
	C.webkit_web_view_load_uri(r.webview, C.CString(url))

	// Transparent background.
	rgba := C.GdkRGBA{red: 0, green: 0, blue: 0, alpha: 0}
	C.webkit_web_view_set_background_color(r.webview, &rgba)

	// Enable WebGL.
	settings := C.webkit_web_view_get_settings(r.webview)
	C.webkit_settings_set_enable_webgl((*C.WebKitSettings)(unsafe.Pointer(settings)), C.TRUE)
	C.webkit_settings_set_enable_write_console_messages_to_stdout(
		(*C.WebKitSettings)(unsafe.Pointer(settings)), C.TRUE)

	// Register the JS→Go bridge: window.webkit.messageHandlers.bridge.postMessage().
	manager := C.webkit_web_view_get_user_content_manager(r.webview)
	cBridgeName := C.CString("bridge")
	C.webkit_user_content_manager_register_script_message_handler(manager, cBridgeName)
	C.free(unsafe.Pointer(cBridgeName))

	// Connect "script-message-received::bridge" → exported Go callback.
	csig := C.CString("script-message-received::bridge")
	C.c_signal_connect(C.gpointer(manager), csig, C.GCallback(C.go_message_received_cb), nil)
	C.free(unsafe.Pointer(csig))

	// Connect "destroy" → exported Go callback.
	csig2 := C.CString("destroy")
	C.c_signal_connect(C.gpointer(window), csig2, C.GCallback(C.go_window_destroy_cb), nil)
	C.free(unsafe.Pointer(csig2))

	C.gtk_container_add((*C.GtkContainer)(unsafe.Pointer(window)), webview)
	C.gtk_widget_show_all(window)

	return r, nil
}

// SendMessage marshals a message and evaluates JS on the GTK main thread.
func (r *gtkRenderer) SendMessage(msg any) {
	data, err := json.Marshal(msg)
	if err != nil {
		log.Printf("renderer: marshal error: %v", err)
		return
	}
	js := "if(window.handleMessage)handleMessage(" + strconv.Quote(string(data)) + ")"
	cjs := C.CString(js)
	defer C.free(unsafe.Pointer(cjs))
	C.scheduleEval(r.webview, cjs)
}

// Events returns the channel of user events from JS.
func (r *gtkRenderer) Events() <-chan brain.Event {
	return r.events
}

// Run blocks running the GTK main loop until the window closes.
func (r *gtkRenderer) Run() {
	C.gtk_main()
	close(r.done)
}

// Close quits the GTK main loop.
func (r *gtkRenderer) Close() {
	C.gtk_main_quit()
}

// ── Exported C callbacks ───────────────────────────────────

//export go_message_received_cb
func go_message_received_cb(manager *C.WebKitUserContentManager, result *C.WebKitJavascriptResult, userdata C.gpointer) {
	rendererMu.Lock()
	r := activeRenderer
	rendererMu.Unlock()
	if r == nil {
		return
	}

	jsValue := C.webkit_javascript_result_get_js_value(result)
	if jsValue == nil {
		return
	}

	cstr := C.jsc_value_to_string(jsValue)
	if cstr == nil {
		return
	}
	defer C.free(unsafe.Pointer(cstr))

	msg := C.GoString(cstr)
	var ev brain.Event
	if err := json.Unmarshal([]byte(msg), &ev); err != nil {
		log.Printf("renderer: bad message from JS: %v (raw: %s)", err, msg)
		return
	}

	select {
	case r.events <- ev:
	default:
		log.Printf("renderer: dropping event (channel full): %s", ev.Type)
	}
}

//export go_window_destroy_cb
func go_window_destroy_cb(widget *C.GtkWidget, userdata C.gpointer) {
	C.gtk_main_quit()
}