//
//  SherpaTtsEngine.swift
//  SiriApp
//
//  Offline TTS engine using sherpa-onnx VITS model.
//  Calls sherpa-onnx C API via bridging header.
//  Ported from Android: SherpaTtsEngine.kt
//

import Foundation
import os.log

class SherpaTtsEngine {
    private let modelDir: URL
    private let vitsModel = "model.onnx"
    private let tokensFile = "tokens.txt"
    private let lexiconFile = "lexicon.txt"
    private let dataDirName = "espeak-ng-data"  // optional, for better pronunciation

    static let defaultSpeed: Float = 1.0
    static let defaultSampleRate: Int32 = 22050

    private var tts: OpaquePointer?
    private var isInitialized = false

    init(documentsDir: URL) {
        self.modelDir = documentsDir
            .appendingPathComponent("models/tts")
    }

    var isReady: Bool { isInitialized }

    /// Number of speakers supported by the loaded VITS model.
    /// Returns 0 if the engine is not initialized. Single-speaker models return 1.
    var numSpeakers: Int {
        guard isInitialized, let tts = tts else { return 0 }
        return Int(SherpaOnnxOfflineTtsNumSpeakers(tts))
    }

    var sampleRate: Int32 {
        guard isInitialized, let tts = tts else { return SherpaTtsEngine.defaultSampleRate }
        return SherpaOnnxOfflineTtsSampleRate(tts)
    }

    func initialize() -> Bool {
        guard !isInitialized else { return true }

        let modelPath = modelDir.appendingPathComponent(vitsModel).path
        let tkPath = modelDir.appendingPathComponent(tokensFile).path
        let lxPath = modelDir.appendingPathComponent(lexiconFile).path
        let dataDir = modelDir.appendingPathComponent(dataDirName)

        let fm = FileManager.default
        let missing = [modelPath, tkPath, lxPath].filter { !fm.fileExists(atPath: $0) }
        if !missing.isEmpty {
            os_log(.error, "TTS: missing model files: %{public}@",
                   missing.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
            return false
        }

        let numThreads = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount))
        os_log(.info, "TTS: initializing VITS with numThreads=%d", numThreads)

        var config = SherpaOnnxOfflineTtsConfig()
        memset(&config, 0, MemoryLayout<SherpaOnnxOfflineTtsConfig>.size)

        let modelPtr = strdup(modelPath)
        let tkPtr = strdup(tkPath)
        let lxPtr = strdup(lxPath)
        let dataPtr = fm.fileExists(atPath: dataDir.path) ? strdup(dataDir.path) : nil
        let providerPtr = strdup("xnnpack")

        config.model.vits.model = UnsafePointer(modelPtr)
        config.model.vits.tokens = UnsafePointer(tkPtr)
        config.model.vits.lexicon = UnsafePointer(lxPtr)
        config.model.vits.data_dir = dataPtr.map { UnsafePointer($0) }
        config.model.num_threads = Int32(numThreads)
        config.model.provider = UnsafePointer(providerPtr)
        config.max_num_sentences = 1  // one sentence at a time for streaming

        tts = SherpaOnnxCreateOfflineTts(&config)

        // Free strdup'd strings
        free(modelPtr)
        free(tkPtr)
        free(lxPtr)
        if let dataPtr = dataPtr { free(dataPtr) }
        free(providerPtr)

        isInitialized = tts != nil

        if isInitialized {
            os_log(.info, "TTS: initialized OK, sample_rate=%d, num_speakers=%d", sampleRate, numSpeakers)
        } else {
            os_log(.error, "TTS: failed to create engine")
        }
        return isInitialized
    }

    func synthesize(text: String, speed: Float = defaultSpeed, sid: Int = 0) -> [Float]? {
        guard isInitialized, let tts = tts else { return nil }

        os_log(.info, "TTS: synthesizing %d chars, speed=%.2f", text.count, speed)

        var genConfig = SherpaOnnxGenerationConfig()
        memset(&genConfig, 0, MemoryLayout<SherpaOnnxGenerationConfig>.size)
        genConfig.sid = Int32(sid)
        genConfig.speed = speed

        let audio = text.withCString { textPtr in
            SherpaOnnxOfflineTtsGenerateWithConfig(
                tts, textPtr, &genConfig, nil, nil
            )
        }

        guard let audio = audio, audio.pointee.n > 0, let samples = audio.pointee.samples else {
            if let audio = audio {
                SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio)
            }
            os_log(.error, "TTS: generation produced no audio")
            return nil
        }

        let n = Int(audio.pointee.n)
        let result = Array(UnsafeBufferPointer(start: samples, count: n))
        let sr = audio.pointee.sample_rate
        SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio)

        os_log(.info, "TTS: synthesized %d samples at %d Hz", n, sr)
        return result
    }

    func destroy() {
        guard isInitialized, let tts = tts else { return }

        SherpaOnnxDestroyOfflineTts(tts)
        self.tts = nil
        isInitialized = false
        os_log(.info, "TTS: destroyed")
    }
}
