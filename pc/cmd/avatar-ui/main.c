// avatar-ui — GTK + WebKit2GTK window host for the Avatar PC digital human.
//
// Runs as a child process controlled by the Go backend over stdin/stdout
// pipes. Keeping WebKit in a separate process avoids the signal conflict
// between the Go runtime and WebKit's JavaScriptCore (JSC_SIGNAL_FOR_GC),
// which is unsolvable in a single process.
//
// Protocol (one JSON object per line, '\n'-terminated):
//   Go -> C (stdin):
//     {"cmd":"eval","js":"<javascript>"}   execute JS in the webview
//     {"cmd":"quit"}                       close the window and exit
//   C -> Go (stdout):
//     <json string>                        event from the JS bridge (verbatim)
//
// Build:
//   gcc -O2 -o avatar-ui main.c $(pkg-config --cflags --libs gtk+-3.0 webkit2gtk-4.1)

#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

#include <glib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// ─── Tiny JSON helpers (we only need to parse our own two commands) ───

// Extract a JSON string value for `key` from a flat object, unescaping it
// into a newly allocated string. Returns 1 on success, 0 if absent/malformed.
// The caller owns *out and must g_free() it.
static int json_get_string(const char *json, const char *key, char **out) {
    char needle[128];
    snprintf(needle, sizeof(needle), "\"%s\"", key);

    const char *p = strstr(json, needle);
    if (!p)
        return 0;
    p += strlen(needle);

    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')
        p++;
    if (*p != ':')
        return 0;
    p++;
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')
        p++;
    if (*p != '"')
        return 0;
    p++;

    GString *s = g_string_new(NULL);
    while (*p && *p != '"') {
        if (*p != '\\') {
            g_string_append_c(s, *p);
            p++;
            continue;
        }
        p++;
        switch (*p) {
        case '"':  g_string_append_c(s, '"');  p++; break;
        case '\\': g_string_append_c(s, '\\'); p++; break;
        case '/':  g_string_append_c(s, '/');  p++; break;
        case 'b':  g_string_append_c(s, '\b'); p++; break;
        case 'f':  g_string_append_c(s, '\f'); p++; break;
        case 'n':  g_string_append_c(s, '\n'); p++; break;
        case 'r':  g_string_append_c(s, '\r'); p++; break;
        case 't':  g_string_append_c(s, '\t'); p++; break;
        case 'u': {
            // \uXXXX — our JS payloads are ASCII + BMP (Chinese), so a single
            // code unit is sufficient; surrogate pairs are not needed here.
            unsigned int cp = 0;
            for (int i = 0; i < 4 && p[i + 1]; i++) {
                char c = p[i + 1];
                cp <<= 4;
                if (c >= '0' && c <= '9')      cp |= (unsigned)(c - '0');
                else if (c >= 'a' && c <= 'f') cp |= (unsigned)(c - 'a' + 10);
                else if (c >= 'A' && c <= 'F') cp |= (unsigned)(c - 'A' + 10);
            }
            g_string_append_unichar(s, cp);
            p += 5;
            break;
        }
        default:
            g_string_append_c(s, *p);
            p++;
            break;
        }
    }

    *out = g_string_free(s, FALSE);
    return 1;
}

// ─── JS → Go bridge ────────────────────────────────────────────────

static GtkWidget *g_window = NULL;

static void on_script_message(WebKitUserContentManager *manager,
                              WebKitJavascriptResult  *result,
                              gpointer                 user_data) {
    (void)manager;
    (void)user_data;

    JSCValue *value = webkit_javascript_result_get_js_value(result);
    gchar *str = jsc_value_to_string(value);
    if (str) {
        printf("%s\n", str);
        fflush(stdout);
        g_free(str);
    }
}

// ─── JS → C resize handler (auto-fit window to avatar bounds) ──────

static void on_resize_message(WebKitUserContentManager *manager,
                              WebKitJavascriptResult  *result,
                              gpointer                 user_data) {
    (void)manager;
    (void)user_data;

    JSCValue *value = webkit_javascript_result_get_js_value(result);
    gchar *str = jsc_value_to_string(value);
    if (!str) return;

    // Parse {"width":N,"height":M} manually.
    int w = 0, h = 0;
    const char *p = str;
    const char *wpos = strstr(p, "\"width\"");
    const char *hpos = strstr(p, "\"height\"");
    if (wpos) { wpos += 7; while (*wpos && (*wpos < '0' || *wpos > '9')) wpos++; w = (int)strtol(wpos, NULL, 10); }
    if (hpos) { hpos += 8; while (*hpos && (*hpos < '0' || *hpos > '9')) hpos++; h = (int)strtol(hpos, NULL, 10); }

    if (w >= 100 && h >= 100 && w <= 2000 && h <= 2000)
        gtk_window_resize(GTK_WINDOW(g_window), w, h);

    g_free(str);
}

// ─── JS → C move handler (WASD / Ctrl+drag → move window) ────

static void on_move_message(WebKitUserContentManager *manager,
                            WebKitJavascriptResult  *result,
                            gpointer                 user_data) {
    (void)manager;
    (void)user_data;

    JSCValue *value = webkit_javascript_result_get_js_value(result);
    gchar *str = jsc_value_to_string(value);
    if (!str) return;

    // Parse {"dx":N,"dy":M} manually.
    int dx = 0, dy = 0;
    const char *dxpos = strstr(str, "\"dx\"");
    const char *dypos = strstr(str, "\"dy\"");
    if (dxpos) { dxpos += 4; while (*dxpos && *dxpos != '-' && (*dxpos < '0' || *dxpos > '9')) dxpos++; dx = (int)strtol(dxpos, NULL, 10); }
    if (dypos) { dypos += 4; while (*dypos && *dypos != '-' && (*dypos < '0' || *dypos > '9')) dypos++; dy = (int)strtol(dypos, NULL, 10); }

    if (dx != 0 || dy != 0) {
        gint wx, wy;
        gtk_window_get_position(GTK_WINDOW(g_window), &wx, &wy);
        gint new_x = wx + dx;
        gint new_y = wy + dy;

        // Clamp to screen bounds so the window is never fully off-screen.
        // Keep at least 80px of the window visible on every edge.
        GdkMonitor *monitor = gdk_display_get_primary_monitor(
            gdk_display_get_default());
        GdkRectangle geom;
        gdk_monitor_get_geometry(monitor, &geom);
        gint scr_w = geom.width;
        gint scr_h = geom.height;
        gint win_w = 0, win_h = 0;
        gtk_window_get_size(GTK_WINDOW(g_window), &win_w, &win_h);

        gint min_visible = 80;
        if (new_x < min_visible - win_w) new_x = min_visible - win_w;
        if (new_x > scr_w - min_visible) new_x = scr_w - min_visible;
        if (new_y < min_visible - win_h) new_y = min_visible - win_h;
        if (new_y > scr_h - min_visible) new_y = scr_h - min_visible;

        gtk_window_move(GTK_WINDOW(g_window), new_x, new_y);
    }

    g_free(str);
}

// ─── Window dragging (undecorated window has no title bar) ────────

// Drag state: we distinguish a "tap" (press + release without moving, which
// the webview turns into a JS click → tap event) from a "drag" (press + move
// past a threshold, which moves the window). We move the window manually so we
// can clamp it to the screen edges — gtk_window_begin_move_drag() would give
// GTK control and we couldn't clamp.
static gboolean g_dragging = FALSE;
static gint     g_win_x = 0, g_win_y = 0;   // window position at drag start
static gdouble  g_press_x = 0, g_press_y = 0; // pointer position at drag start

static gboolean on_button_press(GtkWidget *w, GdkEventButton *ev, gpointer data) {
    (void)w; (void)data;
    if (ev->button == 1) {
        gtk_window_get_position(GTK_WINDOW(g_window), &g_win_x, &g_win_y);
        g_press_x = ev->x_root;
        g_press_y = ev->y_root;
        g_dragging = FALSE; // not dragging yet — wait for the threshold
    }
    return FALSE; // let the webview handle the click normally
}

static gboolean on_motion_notify(GtkWidget *w, GdkEventMotion *ev, gpointer data) {
    (void)w; (void)data;
    if (!(ev->state & GDK_BUTTON1_MASK)) return FALSE;
    if (!g_dragging) {
        // Check if we've moved past the 5px threshold.
        gdouble dx = ev->x_root - g_press_x;
        gdouble dy = ev->y_root - g_press_y;
        if (dx * dx + dy * dy <= 25.0) return FALSE;
        g_dragging = TRUE;
    }

    // Compute desired new window position.
    gint new_x = (gint)(g_win_x + (ev->x_root - g_press_x));
    gint new_y = (gint)(g_win_y + (ev->y_root - g_press_y));

    // Clamp to screen bounds so the window is never fully off-screen.
    // Keep at least 80px of the window visible on every edge.
    GdkMonitor *monitor = gdk_display_get_primary_monitor(
        gdk_display_get_default());
    GdkRectangle geom;
    gdk_monitor_get_geometry(monitor, &geom);
    gint scr_w = geom.width;
    gint scr_h = geom.height;
    gint win_w = 0, win_h = 0;
    gtk_window_get_size(GTK_WINDOW(g_window), &win_w, &win_h);

    gint min_visible = 80;
    if (new_x < min_visible - win_w) new_x = min_visible - win_w;
    if (new_x > scr_w - min_visible) new_x = scr_w - min_visible;
    if (new_y < min_visible - win_h) new_y = min_visible - win_h;
    if (new_y > scr_h - min_visible) new_y = scr_h - min_visible;

    gtk_window_move(GTK_WINDOW(g_window), new_x, new_y);
    return FALSE;
}

static gboolean on_button_release(GtkWidget *w, GdkEventButton *ev, gpointer data) {
    (void)w; (void)ev; (void)data;
    g_dragging = FALSE;
    return FALSE;
}

// ─── Go → JS commands (read from stdin on the GTK main loop) ──────

static WebKitWebView *g_webview = NULL;

static gboolean on_stdin(GIOChannel *channel, GIOCondition cond, gpointer user_data) {
    (void)user_data;

    if (cond & (G_IO_HUP | G_IO_ERR)) {
        // Go process is gone — shut down.
        gtk_main_quit();
        return G_SOURCE_REMOVE;
    }

    gchar *line = NULL;
    gsize  len = 0;
    GIOStatus status = g_io_channel_read_line(channel, &line, &len, NULL, NULL);

    if (status == G_IO_STATUS_EOF || status == G_IO_STATUS_ERROR) {
        g_free(line);
        gtk_main_quit();
        return G_SOURCE_REMOVE;
    }
    if (status != G_IO_STATUS_NORMAL) {
        g_free(line);
        return G_SOURCE_CONTINUE;
    }

    char *cmd = NULL;
    if (json_get_string(line, "cmd", &cmd)) {
        if (strcmp(cmd, "quit") == 0) {
            g_free(cmd);
            g_free(line);
            gtk_main_quit();
            return G_SOURCE_REMOVE;
        }
        if (strcmp(cmd, "eval") == 0) {
            char *js = NULL;
            if (json_get_string(line, "js", &js) && js) {
                webkit_web_view_evaluate_javascript(
                    g_webview, js, -1, NULL, NULL, NULL, NULL, NULL);
                g_free(js);
            }
        }
        g_free(cmd);
    }

    g_free(line);
    return G_SOURCE_CONTINUE;
}

// ─── Main ─────────────────────────────────────────────────────────

int main(int argc, char **argv) {
    // Force the X11 backend (via XWayland on a Wayland session). Transparent
    // ARGB windows do not work through the native Wayland backend; XWayland +
    // the compositor renders them correctly. Must be set before gtk_init.
    if (!g_getenv("GDK_BACKEND"))
        g_setenv("GDK_BACKEND", "x11", TRUE);

    gtk_init(&argc, &argv);

    const char *url = "http://127.0.0.1:34023/index.html";
    if (argc > 1)
        url = argv[1];

    // ── Window: undecorated, transparent, portrait ──
    GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    g_window = window;
    gtk_window_set_title(GTK_WINDOW(window), "Avatar PC");
    gtk_window_set_decorated(GTK_WINDOW(window), FALSE); // no title bar
    gtk_window_set_default_size(GTK_WINDOW(window), 480, 720);
    gtk_window_set_resizable(GTK_WINDOW(window), FALSE);
    gtk_window_set_keep_above(GTK_WINDOW(window), TRUE); // float on top
    // Let the window paint its own (transparent) background.
    gtk_widget_set_app_paintable(window, TRUE);

    // Enable RGBA visual so the window background can be transparent.
    GdkScreen *screen = gtk_widget_get_screen(window);
    GdkVisual *visual = gdk_screen_get_rgba_visual(screen);
    if (visual)
        gtk_widget_set_visual(window, visual);

    // ── WebView ──
    WebKitWebView *webview = WEBKIT_WEB_VIEW(webkit_web_view_new());
    g_webview = webview;
    webkit_web_view_load_uri(webview, url);

    // Transparent background.
    GdkRGBA rgba = {0, 0, 0, 0};
    webkit_web_view_set_background_color(webview, &rgba);
    // The webview itself must also be app-paintable so the alpha channel
    // actually reaches the compositor.
    gtk_widget_set_app_paintable(GTK_WIDGET(webview), TRUE);

    // Enable WebGL and console logging.
    WebKitSettings *settings = webkit_web_view_get_settings(webview);
    webkit_settings_set_enable_webgl(settings, TRUE);
    webkit_settings_set_enable_write_console_messages_to_stdout(settings, TRUE);

    // Register the JS→Go bridge:
    //   window.webkit.messageHandlers.bridge.postMessage()
    WebKitUserContentManager *manager =
        webkit_web_view_get_user_content_manager(webview);
    webkit_user_content_manager_register_script_message_handler(manager, "bridge");
    webkit_user_content_manager_register_script_message_handler(manager, "resize");
    webkit_user_content_manager_register_script_message_handler(manager, "move");
    g_signal_connect(manager, "script-message-received::bridge",
                     G_CALLBACK(on_script_message), NULL);
    g_signal_connect(manager, "script-message-received::resize",
                     G_CALLBACK(on_resize_message), NULL);
    g_signal_connect(manager, "script-message-received::move",
                     G_CALLBACK(on_move_message), NULL);

    // Window close → quit.
    g_signal_connect(window, "destroy", G_CALLBACK(gtk_main_quit), NULL);

    // Connect drag signals directly to the WebView. The WebView has its
    // own GDK window, so wrapping it in an EventBox won't capture events
    // (they go to the deepest GDK window, i.e. the WebView's).
    // We need GDK_POINTER_MOTION_MASK and GDK_BUTTON1_MOTION_MASK on the
    // WebView's GDK window so motion-notify-event fires.
    gtk_widget_add_events(GTK_WIDGET(webview),
        GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK |
        GDK_POINTER_MOTION_MASK | GDK_BUTTON1_MOTION_MASK);
    g_signal_connect(webview, "button-press-event", G_CALLBACK(on_button_press), NULL);
    g_signal_connect(webview, "motion-notify-event", G_CALLBACK(on_motion_notify), NULL);
    g_signal_connect(webview, "button-release-event", G_CALLBACK(on_button_release), NULL);

    gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(webview));
    gtk_widget_show_all(window);

    // Watch stdin for commands on the GTK main loop.
    GIOChannel *in = g_io_channel_unix_new(STDIN_FILENO);
    g_io_channel_set_encoding(in, NULL, NULL); // binary
    g_io_add_watch(in, G_IO_IN | G_IO_HUP | G_IO_ERR, on_stdin, NULL);

    gtk_main();

    g_io_channel_unref(in);
    return 0;
}
