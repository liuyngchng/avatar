//
//  WakeWordManager.swift
//  SiriApp
//
//  Singleton coordinating wake word detection state between
//  WakeWordEngine and the UI layer (MainViewModel).
//  Ported from Android: WakeWordManager.kt
//

import Foundation
import Combine
import os.log

final class WakeWordManager {
    static let shared = WakeWordManager()

    // MARK: - Publishers

    /// Emitted when the wake word is detected.
    let wakeEvents = PassthroughSubject<Void, Never>()

    /// Whether KWS detection is currently running.
    @Published private(set) var isRunning = false

    /// Signal emitted when the voice flow completes and KWS should resume.
    let resumeSignal = PassthroughSubject<Void, Never>()

    // MARK: - Adaptive Debounce

    private let baseDebounceMs: TimeInterval = 5.0
    private let maxDebounceMs: TimeInterval = 120.0
    private var consecutiveFalseTriggers = 0

    /// Current debounce window based on recent false-trigger history.
    var currentDebounceSec: TimeInterval {
        if consecutiveFalseTriggers == 0 { return baseDebounceMs }
        let doubled = baseDebounceMs * pow(2.0, Double(consecutiveFalseTriggers))
        return min(doubled, maxDebounceMs)
    }

    private init() {}

    // MARK: - State Updates

    /// Called when the wake word is detected.
    func notifyWakeWord() {
        wakeEvents.send()
    }

    /// Called after a wake-word-triggered voice session completed successfully.
    /// Resets the adaptive debounce counter.
    func notifyProductiveWake() {
        if consecutiveFalseTriggers > 0 {
            os_log(.info, "WakeWordManager: resetting debounce (was %d consecutive false triggers)",
                   consecutiveFalseTriggers)
            consecutiveFalseTriggers = 0
        }
    }

    /// Called when a wake-word-triggered session produced no meaningful speech.
    /// Increases the debounce window.
    func notifyFalseTrigger() {
        consecutiveFalseTriggers += 1
        os_log(.info, "WakeWordManager: false trigger #%d, debounce=%.0fs",
               consecutiveFalseTriggers, currentDebounceSec)
    }

    /// Called when the voice flow (ASR→LLM→TTS) has completed.
    func notifyVoiceFlowDone() {
        resumeSignal.send()
    }

    /// Update the running state.
    func setRunning(_ running: Bool) {
        isRunning = running
    }
}
