//
//  RobotState.swift
//  Avatar
//
//  Core data model for the stick-figure companion.
//  Ported from Android: RobotState.kt
//

import Foundation

/// Top-level behavior state (FSM)
enum RobotMode: Equatable {
    /// Idle, waiting for interaction. Stick figure does random goofy antics.
    case idle

    /// User tapped or said wake word — waiting for speech input.
    case listening

    /// Stick figure is speaking (TTS active). Mouth + arm gestures animate.
    case speaking

    /// Processing request (e.g., waiting on LLM response).
    case thinking

    /// Camera is active (rear camera, on-demand). Stick figure holds a "camera" pose.
    case looking
}

/// Emotional state — drives expression and tone
enum Emotion: CaseIterable {
    case neutral
    case happy
    case curious
    case surprised
    case shy
    case sleepy
    case sad
    /// Goofy / silly mood — for random antics
    case goofy

    var intensity: Float {
        switch self {
        case .neutral:    return 0.5
        case .happy:      return 0.8
        case .curious:    return 0.6
        case .surprised:  return 0.9
        case .shy:        return 0.4
        case .sleepy:     return 0.3
        case .sad:        return 0.3
        case .goofy:      return 0.9
        }
    }
}

/// Current stick figure state, consumed by UI and behavior engine.
struct RobotState {
    var mode: RobotMode = .idle

    /// Current emotion
    var emotion: Emotion = .neutral

    /// Whether engines (ASR + TTS) are initialized and ready
    var enginesReady: Bool = false

    /// Whether TTS is currently producing audio
    var isSpeaking: Bool = false

    /// Last recognized user utterance
    var lastUserText: String? = nil

    /// Response text to speak
    var responseText: String? = nil

    /// Blink trigger — UI toggles each time this changes
    var blinkTrigger: Int = 0

    /// Random antic trigger — increments to make the stick figure do something goofy
    var anticTrigger: Int = 0

    /// When LOOKING: a description of what the camera saw (filled by LLM or local logic)
    var cameraObservation: String? = nil
}
