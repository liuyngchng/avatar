//
//  DesignTokens.swift
//  SiriApp
//
//  Centralised design constants for HIG-compliant styling.
//  Colours use system semantic colours; spacing follows an 8-pt grid.
//

import SwiftUI

// MARK: - Colours

enum ChatColors {

    // -- Bubble ---
    static let userBubbleBackground  = Color.blue
    static let userBubbleText        = Color(.systemBackground)
    static let assistantBubbleBackground = Color(.systemGray5)
    static let assistantBubbleText   = Color(.label)

    // -- Mic button ---
    static let micIdleBackground     = Color(.systemGray5)
    static let micIdleForeground     = Color.blue
    static let micActiveBackground   = Color.blue
    static let micActiveForeground   = Color.white
    static let micSpeakingBackground = Color.red
    static let micSpeakingForeground = Color.white

    // -- Typography ---
    static let secondaryLabel        = Color(.secondaryLabel)
    static let tertiaryLabel         = Color(.tertiaryLabel)

    // -- Thinking / empty state ---
    static let thinkingForeground    = Color(.secondaryLabel)
    static let thinkingTint          = Color.blue
    static let emptyStateAccent      = Color.blue
    static let emptyStatePrimary     = Color(.label)
    static let emptyStateSecondary   = Color(.secondaryLabel)
}

// MARK: - Spacing (8-pt grid)

enum ChatSpacing {
    static let pt2:  CGFloat = 2
    static let pt4:  CGFloat = 4
    static let pt6:  CGFloat = 6
    static let pt8:  CGFloat = 8
    static let pt12: CGFloat = 12
    static let pt16: CGFloat = 16
    static let pt20: CGFloat = 20
    static let pt24: CGFloat = 24
    static let pt32: CGFloat = 32

    /// Horizontal padding for the message list content.
    static let listHorizontal: CGFloat = pt16

    /// Vertical spacing between messages from the same sender (tight grouping).
    static let sameSenderSpacing: CGFloat = pt4
    /// Vertical spacing between messages from different senders.
    static let differentSenderSpacing: CGFloat = pt12
    /// Extra top inset for the first message below the nav bar.
    static let listTopInset: CGFloat = pt4
    /// Bottom inset of the scroll-view content.
    static let listBottomInset: CGFloat = pt16
}

// MARK: - Bubble Metrics

enum ChatBubbleMetrics {
    /// Maximum bubble width as a fraction of the available width.
    static let maxWidthFraction: CGFloat = 0.80
    /// Hard cap for bubble width on iPad landscape.
    static let maxWidthCap: CGFloat = 480
    /// Corner radius for message bubbles.
    static let cornerRadius: CGFloat = 18
    /// Corner radius for secondary containers (thinking indicator, etc.).
    static let smallCornerRadius: CGFloat = 12
    /// Horizontal padding inside a bubble.
    static let textHPadding: CGFloat = 14
    /// Vertical padding inside a bubble.
    static let textVPadding: CGFloat = 11
    /// Minimum space from the bubble edge to the screen edge.
    static let edgeMinimum: CGFloat = 52
}

// MARK: - Mic Button Metrics

enum MicButtonMetrics {
    /// Default button diameter at standard Dynamic Type size.
    static let defaultSize: CGFloat = 72
    /// Icon font-size multiplier relative to button diameter.
    static let iconScale: CGFloat = 0.38
    /// Scale applied when the button is pressed.
    static let pressScale: CGFloat = 0.88
    /// Pulse ring size multiplier relative to button diameter.
    static let pulseRingScale: CGFloat = 1.5
}
