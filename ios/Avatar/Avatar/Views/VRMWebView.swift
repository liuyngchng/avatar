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

    private(set) weak var webView: WKWebView?

    private init() {}

    func register(_ webView: WKWebView) {
        self.webView = webView
    }

    func send(_ jsonString: String) {
        guard let webView = webView else { return }
        DispatchQueue.main.async {
            let escaped = jsonString
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "")
            let js = "handleMessage('\(escaped)')"
            webView.evaluateJavaScript(js) { _, error in
                if let error = error {
                    os_log(.error, "VRMWebView: evaluateJavaScript error: %{public}@",
                           error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - WKWebView Coordinator

class VRMWebViewCoordinator: NSObject, WKScriptMessageHandler {
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "bridge",
              let body = message.body as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
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

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.backgroundColor = UIColor(red: 0.10, green: 0.10, blue: 0.18, alpha: 1.0)
        webView.isOpaque = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.showsVerticalScrollIndicator = false

        VRMBridge.shared.register(webView)

        if let htmlURL = Bundle.main.url(
            forResource: "index", withExtension: "html", subdirectory: "web"
        ) {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
            os_log(.info, "VRMWebView: loading %{public}@", htmlURL.path)
        } else {
            os_log(.error, "VRMWebView: index.html not found in bundle")
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}