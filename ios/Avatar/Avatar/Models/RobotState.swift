//
//  RobotState.swift
//  Avatar
//
//  Core data model for the robot companion.
//  Ported from Android: RobotState.kt
//

import Foundation

/// Top-level behavior state (FSM)
enum RobotMode: Equatable {
    /// Idle, waiting for interaction. Eyes wander, occasional blinks.
    case idle

    /// User tapped or said wake word — waiting for speech input.
    case listening

    /// Robot is speaking (TTS active). Mouth animates.
    case speaking

    /// Human face detected — engaged, eyes follow face.
    case watching

    /// Processing request (e.g., waiting on LLM response).
    case thinking
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

    var intensity: Float {
        switch self {
        case .neutral:    return 0.5
        case .happy:      return 0.8
        case .curious:    return 0.6
        case .surprised:  return 0.9
        case .shy:        return 0.4
        case .sleepy:     return 0.3
        case .sad:        return 0.3
        }
    }
}

/// Current robot state, consumed by UI and behavior engine.
struct RobotState {
    var mode: RobotMode = .idle

    /// Detected face bounding box center, normalized 0..1, or nil
    var faceTargetX: Float? = nil
    var faceTargetY: Float? = nil

    /// Current emotion
    var emotion: Emotion = .neutral

    /// Whether TTS is currently producing audio
    var isSpeaking: Bool = false

    /// Last recognized user utterance
    var lastUserText: String? = nil

    /// Response text to speak
    var responseText: String? = nil

    /// Blink trigger — UI toggles each time this changes
    var blinkTrigger: Int = 0

    /// Time since last face detection in ms
    var msSinceLastFace: Int = 0
}
