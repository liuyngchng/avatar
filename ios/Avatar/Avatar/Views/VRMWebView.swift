//
//  VRMWebView.swift
//  Avatar
//
//  WKWebView wrapper that loads the three.js VRM rendering page.
//  Handles JS→Swift bridge for tap/long-press events.
//  Provides VRMBridge singleton for Swift→JS state/viseme messages.
//

import SwiftUI
import WebKit
import os.log

// MARK: - VRMBridge (singleton for Swift→JS communication)

final class VRMBridge {
    static let shared = VRMBridge()

    private weak var webView: WKWebView?
    private var isPageLoaded = false
    private var pendingMessages: [String] = []

    private init() {}

    func register(_ webView: WKWebView) {
        self.webView = webView
    }

    /// Called by WKNavigationDelegate when the page finishes loading.
    func onPageLoaded() {
        isPageLoaded = true
        let msgs = pendingMessages
        pendingMessages = []
        for msg in msgs {
            sendImmediate(msg)
        }
    }

    func send(_ jsonString: String) {
        guard webView != nil else { return }
        if isPageLoaded {
            sendImmediate(jsonString)
        } else {
            pendingMessages.append(jsonString)
        }
    }

    private func sendImmediate(_ jsonString: String) {
        guard let webView = webView else { return }
        DispatchQueue.main.async {
            let escaped = jsonString
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "")
            let js = "handleMessage('\(escaped)')"
            webView.evaluateJavaScript(js) { _, error in
                if let error = error as? NSError {
                    let msg = error.userInfo["WKJavaScriptExceptionMessage"] as? String
                        ?? error.localizedDescription
                    os_log(.error, "VRMWebView: evaluateJavaScript error: %{public}@", msg)
                }
            }
        }
    }
}

// MARK: - VRM URL scheme handler

/// WKWebView cannot load ES module scripts over file:// URLs (module fetches
/// fail silently and the page never boots), so the web/ bundle directory is
/// served through a custom "vrm" scheme instead. The page is loaded as
/// vrm://local/index.html and all subresources (JS modules, models, textures)
/// resolve through this handler.
final class VRMURLSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let webDir = Bundle.main.resourceURL?.appendingPathComponent("web") else {
            respond(urlSchemeTask, status: 500, mime: "text/plain", data: Data("web directory unavailable".utf8))
            return
        }

        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let fileURL = webDir.appendingPathComponent(String(path.dropFirst()))

        // Keep reads inside the web directory
        let webPrefix = webDir.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath == webPrefix || filePath.hasPrefix(webPrefix + "/") else {
            respond(urlSchemeTask, status: 403, mime: "text/plain", data: Data("Forbidden".utf8))
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            respond(urlSchemeTask, status: 404, mime: "text/plain", data: Data("Not found".utf8))
            return
        }

        respond(urlSchemeTask, status: 200, mime: mimeType(for: fileURL.pathExtension), data: data)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "json": return "application/json"
        case "vrm", "glb": return "model/gltf-binary"
        case "bin": return "application/octet-stream"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "css": return "text/css"
        case "svg": return "image/svg+xml"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    private func respond(_ task: WKURLSchemeTask, status: Int, mime: String, data: Data) {
        let response = HTTPURLResponse(
            url: task.request.url ?? URL(string: "vrm://local/")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}

// MARK: - WKWebView Coordinator

class VRMWebViewCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?
    /// Retained so the scheme handler outlives the configuration assignment.
    var schemeHandler: VRMURLSchemeHandler?

    // MARK: - WKScriptMessageHandler (JS → Swift)

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "bridge",
              let body = message.body as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            os_log(.error, "VRMWebView: failed to parse bridge message")
            return
        }

        // Forward JS console logs to Swift log
        if let type = json["type"] as? String, type == "log" {
            let level = json["level"] as? String ?? "log"
            let text = json["text"] as? String ?? ""
            switch level {
            case "error":
                os_log(.error, "VRMWebView[js]: %{public}@", text)
            case "warn":
                os_log(.info, "VRMWebView[js warn]: %{public}@", text)
            default:
                os_log(.info, "VRMWebView[js]: %{public}@", text)
            }
            return
        }

        guard let type = json["type"] as? String else {
            os_log(.error, "VRMWebView: failed to parse bridge message")
            return
        }
        switch type {
        case "tap":
            onTap?()
        case "long_press":
            onLongPress?()
        default:
            break
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        os_log(.info, "VRMWebView: page loaded, flushing pending messages")
        VRMBridge.shared.onPageLoaded()
    }
}

// MARK: - VRMWebView (UIViewRepresentable)

struct VRMWebView: UIViewRepresentable {
    let onTap: () -> Void
    let onLongPress: () -> Void

    func makeCoordinator() -> VRMWebViewCoordinator {
        let coordinator = VRMWebViewCoordinator()
        coordinator.onTap = onTap
        coordinator.onLongPress = onLongPress
        return coordinator
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "bridge")
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // ES modules cannot be fetched from file:// URLs in WKWebView, so the
        // page is served over a custom scheme (see VRMURLSchemeHandler).
        let schemeHandler = VRMURLSchemeHandler()
        context.coordinator.schemeHandler = schemeHandler
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "vrm")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.backgroundColor = UIColor(red: 0.10, green: 0.10, blue: 0.18, alpha: 1.0)
        webView.isOpaque = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.showsVerticalScrollIndicator = false

        VRMBridge.shared.register(webView)

        if Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") != nil {
            webView.load(URLRequest(url: URL(string: "vrm://local/index.html")!))
            os_log(.info, "VRMWebView: loading vrm://local/index.html")
        } else {
            os_log(.error, "VRMWebView: web/index.html not found in bundle")
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}