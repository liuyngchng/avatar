//
//  AudioPlayer.swift
//  SiriApp
//
//  Audio playback via AVAudioPlayerNode.
//  Ported from Android: AudioPlayer.kt (AudioTrack MODE_STREAM)
//
//  Sentence-by-sentence streaming: scheduleBuffer plays each chunk,
//  then the node is stopped to clear residual audio before the next
//  sentence starts — preventing audio bleed between sentences.
//

import Foundation
import AVFoundation
import os.log

class AudioPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    private var isPlaying = false
    private var engineStarted = false
    /// Set to `true` when `stop()` is called externally (e.g. pauseRobot).
    /// Guards against callbacks from an in-flight `playSequence` trying to
    /// restart a torn-down engine.
    private var terminated = false

    init() {
        engine.attach(playerNode)
    }

    /// Play a single PCM float buffer. Stops any in-progress playback first.
    /// Calls completion when audio finishes or on error.
    func play(
        pcmFloats: [Float],
        sampleRate: Double = 22050.0,
        completion: (() -> Void)? = nil
    ) {
        terminated = false
        // Stop previous playback and clear any scheduled buffers
        stopNode()

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

        // Connect with correct mono format
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        // Start engine lazily
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

        scheduleChunk(pcmFloats: pcmFloats, format: format, completion: completion)
        os_log(.info, "AudioPlayer: playing %d samples at %.0f Hz", pcmFloats.count, sampleRate)
    }

    /// Play a sequence of PCM chunks with a clean gap between each.
    /// After each chunk finishes, the playerNode is stopped to flush residual
    /// audio before the next chunk starts — prevents audio bleed.
    func playSequence(
        chunks: [[Float]],
        sampleRate: Double = 22050.0,
        completion: (() -> Void)? = nil
    ) {
        terminated = false
        stopNode()

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

        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

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

        playNextChunk(chunks: chunks, index: 0, format: format, sampleRate: sampleRate, completion: completion)
    }

    private func playNextChunk(
        chunks: [[Float]],
        index: Int,
        format: AVAudioFormat,
        sampleRate: Double,
        completion: (() -> Void)?
    ) {
        guard !terminated else {
            completion?()
            return
        }
        guard index < chunks.count else {
            // All chunks played — full stop to release engine
            stop()
            completion?()
            return
        }

        let chunk = chunks[index]
        guard !chunk.isEmpty else {
            playNextChunk(chunks: chunks, index: index + 1, format: format, sampleRate: sampleRate, completion: completion)
            return
        }

        scheduleChunk(pcmFloats: chunk, format: format) { [weak self] in
            guard let self = self else { return }
            // Stop node between chunks to flush residual audio
            self.stopNode()
            // Small gap for natural pause between sentences
            self.playNextChunk(chunks: chunks, index: index + 1, format: format, sampleRate: sampleRate, completion: completion)
        }
    }

    // MARK: - Internals

    /// Schedule a single buffer and start the player node.
    private func scheduleChunk(
        pcmFloats: [Float],
        format: AVAudioFormat,
        completion: (() -> Void)?
    ) {
        // If stop() was called externally while a playSequence was in flight,
        // bail out immediately — the engine has already been torn down.
        guard !terminated else {
            completion?()
            return
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

        if let channelData = buffer.floatChannelData {
            channelData[0].initialize(from: pcmFloats, count: pcmFloats.count)
        }

        isPlaying = true

        playerNode.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async {
                self?.isPlaying = false
                completion?()
            }
        }

        playerNode.play()
    }

    /// Stop the player node without tearing down the engine.
    /// This clears all scheduled buffers — the iOS equivalent of AudioTrack.flush().
    private func stopNode() {
        if playerNode.isPlaying {
            playerNode.stop()
        }
        isPlaying = false
    }

    /// Full stop — tears down engine so other components can start theirs.
    func stop() {
        terminated = true
        stopNode()
        engine.disconnectNodeOutput(playerNode)
        if engine.isRunning {
            engine.stop()
            engineStarted = false
        }
        isPlaying = false
    }

    var isCurrentlyPlaying: Bool {
        isPlaying && playerNode.isPlaying
    }
}
