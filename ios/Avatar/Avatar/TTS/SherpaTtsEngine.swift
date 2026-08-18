//
//  SherpaTtsEngine.swift
//  SiriApp
//
//  Offline TTS engine using sherpa-onnx Matcha-TTS model + Vocos vocoder.
//  Calls sherpa-onnx C API via bridging header.
//

import Foundation
import os.log

class SherpaTtsEngine {
    // MARK: - Paths

    private let modelDir: URL
    private let acousticModel = "model.onnx"
    private let vocoderModel = "vocos.onnx"
    private let tokensFile = "tokens.txt"
    private let lexiconFile = "lexicon.txt"

    // MARK: - State

    static let defaultSpeed: Float = 1.0
    static let defaultSampleRate: Int32 = 22050

    private var tts: OpaquePointer?
    private var isInitialized = false

    init(documentsDir: URL) {
        self.modelDir = documentsDir
            .appendingPathComponent("models/tts")
    }

    var isReady: Bool { isInitialized }

    /// Returns 1 for single-speaker matcha models.
    var numSpeakers: Int {
        guard isInitialized, let tts = tts else { return 0 }
        return Int(SherpaOnnxOfflineTtsNumSpeakers(tts))
    }

    var sampleRate: Int32 {
        guard isInitialized, let tts = tts else { return SherpaTtsEngine.defaultSampleRate }
        return SherpaOnnxOfflineTtsSampleRate(tts)
    }

    /// Returns "Voice 0" for the single-speaker matcha model.
    func speakerName(for sid: Int) -> String {
        "Voice \(sid)"
    }

    // MARK: - Initialize

    /// Use CPU provider — coreml crashes on rotary embedding ops, and
    /// xnnpack can cause issues with certain model architectures (cf. KWS).
    private static let providerCandidates = ["cpu"]

    func initialize() -> Bool {
        guard !isInitialized else { return true }

        let fm = FileManager.default
        let acPath = modelDir.appendingPathComponent(acousticModel).path
        let vcPath = modelDir.appendingPathComponent(vocoderModel).path
        let tkPath = modelDir.appendingPathComponent(tokensFile).path
        let lxPath = modelDir.appendingPathComponent(lexiconFile).path

        let missing = [acPath, vcPath, tkPath, lxPath].filter { !fm.fileExists(atPath: $0) }
        if !missing.isEmpty {
            os_log(.error, "TTS: missing model files: %{public}@",
                   missing.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
            return false
        }

        let cpuCount = ProcessInfo.processInfo.activeProcessorCount
        let numThreads = max(2, min(4, cpuCount))
        os_log(.info, "TTS: initializing, cpuCount=%d, numThreads=%d", cpuCount, numThreads)

        // Try each provider candidate until one succeeds
        for provider in Self.providerCandidates {
            let initStart = CFAbsoluteTimeGetCurrent()

            tts = _createEngine(acPath: acPath, vcPath: vcPath, tkPath: tkPath,
                                lxPath: lxPath, provider: provider, numThreads: numThreads)

            let initMs = (CFAbsoluteTimeGetCurrent() - initStart) * 1000

            if tts != nil {
                isInitialized = true
                os_log(.info, "TTS: initialized OK with provider=%@, numThreads=%d, sample_rate=%d (%.0f ms)",
                       provider, numThreads, sampleRate, initMs)

                // Warm-up: run a short synthesis to compile kernels and warm caches
                _ = synthesize(text: ".", speed: 1.0, sid: 0)
                return true
            }

            os_log(.info, "TTS: provider=%@ failed, trying next candidate (%.0f ms)", provider, initMs)
        }

        os_log(.error, "TTS: all providers failed")
        return false
    }

    private func _createEngine(acPath: String, vcPath: String, tkPath: String,
                                lxPath: String, provider: String,
                                numThreads: Int) -> OpaquePointer? {
        var config = SherpaOnnxOfflineTtsConfig()
        memset(&config, 0, MemoryLayout<SherpaOnnxOfflineTtsConfig>.size)

        let acPtr = strdup(acPath)
        let vcPtr = strdup(vcPath)
        let tkPtr = strdup(tkPath)
        let lxPtr = strdup(lxPath)
        let providerPtr = strdup(provider)

        defer {
            free(acPtr); free(vcPtr); free(tkPtr); free(lxPtr); free(providerPtr)
        }

        config.model.matcha.acoustic_model = UnsafePointer(acPtr)
        config.model.matcha.vocoder = UnsafePointer(vcPtr)
        config.model.matcha.tokens = UnsafePointer(tkPtr)
        config.model.matcha.lexicon = UnsafePointer(lxPtr)
        config.model.matcha.noise_scale = 0.667
        config.model.matcha.length_scale = 1.0
        config.model.num_threads = Int32(numThreads)
        config.model.provider = UnsafePointer(providerPtr)
        config.max_num_sentences = 2

        return SherpaOnnxCreateOfflineTts(&config)
    }

    // MARK: - Synthesize

    func synthesize(text: String, speed: Float = defaultSpeed, sid: Int = 0) -> [Float]? {
        guard isInitialized, let tts = tts else { return nil }

        // Strip emoji and other characters that espeak-ng can't handle.
        let safe = text.unicodeScalars.filter { scalar in
            let cp = scalar.value
            if (0x4E00...0x9FFF).contains(cp) { return true }   // CJK Unified
            if (0x3400...0x4DBF).contains(cp) { return true }   // CJK Ext-A
            if (0x2000...0x206F).contains(cp) { return true }   // General Punctuation
            if (0x3000...0x303F).contains(cp) { return true }   // CJK Punctuation
            if (0xFF00...0xFFEF).contains(cp) { return true }   // Halfwidth/Fullwidth
            if cp < 0x2000 { return true }                       // ASCII range
            return false
        }
        let cleanText = String(String.UnicodeScalarView(safe))

        os_log(.info, "TTS: synthesizing %d chars, speed=%.2f, sid=%d, text=\"%{public}@\"",
               cleanText.count, speed, sid, cleanText)

        let startTime = CFAbsoluteTimeGetCurrent()

        var genConfig = SherpaOnnxGenerationConfig()
        memset(&genConfig, 0, MemoryLayout<SherpaOnnxGenerationConfig>.size)
        genConfig.sid = Int32(sid)
        genConfig.speed = speed

        let audio = cleanText.withCString { textPtr in
            SherpaOnnxOfflineTtsGenerateWithConfig(
                tts, textPtr, &genConfig, nil, nil
            )
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        guard let audio = audio, audio.pointee.n > 0, let samples = audio.pointee.samples else {
            if let audio = audio {
                SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio)
            }
            os_log(.error, "TTS: generation produced no audio after %.1f ms", elapsed)
            return nil
        }

        let n = Int(audio.pointee.n)
        let result = Array(UnsafeBufferPointer(start: samples, count: n))
        let sr = audio.pointee.sample_rate
        let durationSec = Float(n) / Float(sr)
        SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio)

        os_log(.info, "TTS: synthesized %d samples at %d Hz (%.2fs audio) in %.1f ms (%.1fx realtime)",
               n, sr, durationSec, elapsed, Double(durationSec) / (elapsed / 1000.0))
        return result
    }

    // MARK: - Destroy

    func destroy() {
        guard isInitialized, let tts = tts else { return }

        SherpaOnnxDestroyOfflineTts(tts)
        self.tts = nil
        isInitialized = false
        os_log(.info, "TTS: destroyed")
    }
}
