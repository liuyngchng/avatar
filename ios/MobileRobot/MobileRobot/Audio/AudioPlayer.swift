//
//  AudioPlayer.swift
//  SiriApp
//
//  Audio playback via AVAudioPlayerNode.
//  Ported from Android: AudioPlayer.kt (AudioTrack MODE_STATIC)
//

import Foundation
import AVFoundation
import os.log

class AudioPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    private var isPlaying = false
    private var completionCallback: (() -> Void)?
    private var engineStarted = false

    init() {
        engine.attach(playerNode)
    }

    /// Play PCM float samples at given sample rate.
    /// Calls completion when audio finishes playing.
    func play(
        pcmFloats: [Float],
        sampleRate: Double = 22050.0,
        completion: (() -> Void)? = nil
    ) {
        stop()

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            os_log(.error, "AudioPlayer: failed to create audio format")
            completion?()
            return
        }

        // Connect with the correct mono format
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        // Start engine lazily — must happen AFTER connect, or the dangling
        // playerNode will crash AVAudioEngineGraph::Initialize.
        if !engineStarted {
            do {
                try engine.start()
                engineStarted = true
            } catch {
                os_log(.error, "AudioPlayer: engine start failed: %{public}@",
                       error.localizedDescription)
                completion?()
                return
            }
        }

        let frameLength = AVAudioFrameCount(pcmFloats.count)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameLength
        ) else {
            os_log(.error, "AudioPlayer: failed to create PCM buffer")
            completion?()
            return
        }
        buffer.frameLength = frameLength

        // Copy float samples to buffer
        if let channelData = buffer.floatChannelData {
            channelData[0].initialize(from: pcmFloats, count: pcmFloats.count)
        }

        self.completionCallback = completion
        self.isPlaying = true

        playerNode.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async {
                self?.isPlaying = false
                self?.completionCallback?()
                self?.completionCallback = nil
            }
        }

        playerNode.play()
        os_log(.info, "AudioPlayer: playing %d samples at %.0f Hz", pcmFloats.count, sampleRate)
    }

    /// Stop playback immediately.
    /// Also stops the underlying AVAudioEngine so other components (e.g.,
    /// AudioRecorder) can start their own engine without conflict.
    func stop() {
        if playerNode.isPlaying {
            playerNode.stop()
        }
        engine.disconnectNodeOutput(playerNode)
        if engine.isRunning {
            engine.stop()
            engineStarted = false
        }
        isPlaying = false
        completionCallback?()
        completionCallback = nil
    }

    var isCurrentlyPlaying: Bool {
        isPlaying && playerNode.isPlaying
    }
}
