//
//  AudioSessionManager.swift
//  SiriApp
//
//  Configures AVAudioSession for playback & recording.
//  Ported from Android: VoiceService.kt (foreground service + audio routing)
//

import Foundation
import AVFoundation
import os.log

enum AudioSessionManager {

    // MARK: - Interruption Handling

    /// Called when an audio interruption begins (phone call, alarm, etc.).
    /// The handler should stop active recording/playback and pause KWS.
    static var onInterruptionBegan: (() -> Void)?
    /// Called when an audio interruption ends and the app can resume.
    static var onInterruptionEnded: (() -> Void)?

    private static var isObserving = false

    static func startObservingInterruptions() {
        guard !isObserving else { return }
        isObserving = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            switch type {
            case .began:
                os_log(.info, "AudioSession: interruption began")
                onInterruptionBegan?()
            case .ended:
                if let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    os_log(.info, "AudioSession: interruption ended, shouldResume=%{public}@",
                           String(options.contains(.shouldResume)))
                }
                onInterruptionEnded?()
            @unknown default:
                break
            }
        }
    }

    // MARK: - Session Configuration

    static func configure() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try session.setActive(true)
            os_log(.info, "AudioSession configured: playAndRecord")
        } catch {
            os_log(.error, "Failed to configure audio session: %{public}@",
                   error.localizedDescription)
        }
    }

    /// Configure audio session for continuous wake word detection.
    /// Uses `.default` mode (not `.voiceChat`) to avoid routing audio to the
    /// earpiece when the session is reconfigured during active TTS playback.
    static func configureForKws() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
            )
            try session.setActive(true)
            os_log(.info, "AudioSession configured: KWS")
        } catch {
            os_log(.error, "Failed to configure audio session for KWS: %{public}@",
                   error.localizedDescription)
        }
    }

    static func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            os_log(.error, "Failed to deactivate audio session: %{public}@",
                   error.localizedDescription)
        }
    }
}
