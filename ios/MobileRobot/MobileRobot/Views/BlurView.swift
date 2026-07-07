//
//  BlurView.swift
//  SiriApp
//
//  UIKit UIVisualEffectView wrapper for SwiftUI.
//  Available since iOS 8 — no @available check needed.
//

import SwiftUI
import UIKit

struct BlurView: UIViewRepresentable {
    let style: UIBlurEffect.Style

    init(style: UIBlurEffect.Style = .systemMaterial) {
        self.style = style
    }

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}
