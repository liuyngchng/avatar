//
//  SherpaTtsEngine.swift
//  SiriApp
//
//  Offline TTS engine using sherpa-onnx.
//  Supports Kokoro (multi-lang, voice cloning) and VITS (single/multi-speaker).
//  Auto-detects model type by checking for voices.bin (Kokoro).
//  Calls sherpa-onnx C API via bridging header.
//

import Foundation
import os.log

class SherpaTtsEngine {
    enum ModelType {
        case vits
        case kokoro
    }

    /// Voice names for Kokoro multi-lang v1.1 (53 voices, sid 0–52).
    /// Falls back to "Voice N" for unknown models or indices out of range.
    static let kokoroVoiceNames: [String] = [
        // American Female (0–10)
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica",
        "af_kore", "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
        // American Male (11–19)
        "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam",
        "am_michael", "am_onyx", "am_puck", "am_santa",
        // British Female (20–23)
        "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
        // British Male (24–27)
        "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
        // Spanish (28–29)
        "ef_dora", "em_alex",
        // French Female (30)
        "ff_siwis",
        // Hindi (31–34)
        "hf_alpha", "hf_beta", "hm_omega", "hm_psi",
        // Italian (35–36)
        "if_sara", "im_nicola",
        // Japanese (37–41)
        "jf_alpha", "jf_beta", "jf_gamma", "jf_delta", "jm_alpha",
        // Portuguese (42–44)
        "pf_dora", "pm_alex", "pm_omega",
        // Chinese Female (45–48)
        "zf_xiaobei", "zf_xiaoni", "zf_xiaoxiao", "zf_xiaoyi",
        // Chinese Male (49–52)
        "zm_yunjian", "zm_yunxiao", "zm_yunxi", "zm_yunyang",
    ]

    /// Returns a human-readable voice name for the given speaker ID.
    /// Uses the Kokoro voice list when available; falls back to "Voice N".
    func speakerName(for sid: Int) -> String {
        if modelType == .kokoro, sid >= 0, sid < Self.kokoroVoiceNames.count {
            return Self.kokoroVoiceNames[sid]
        }
        return "Voice \(sid)"
    }

    // MARK: - Paths

    private let modelDir: URL
    private let onnxModel = "model.onnx"
    private let tokensFile = "tokens.txt"
    private let lexiconFile = "lexicon.txt"
    private let voicesFile = "voices.bin"          // Kokoro only
    private let espeakDataDir = "espeak-ng-data"    // Kokoro (optional, recommended)

    // FST rule files (Kokoro Chinese text processing)
    private let fstFiles = ["date-zh.fst", "number-zh.fst", "phone-zh.fst"]

    // MARK: - State

    static let defaultSpeed: Float = 1.0
    static let defaultSampleRate: Int32 = 22050

    private var tts: OpaquePointer?
    private var isInitialized = false
    private(set) var modelType: ModelType = .vits

    init(documentsDir: URL) {
        self.modelDir = documentsDir
            .appendingPathComponent("models/tts")
    }

    var isReady: Bool { isInitialized }

    /// Number of speakers (VITS) or voices (Kokoro).
    /// Returns 0 if the engine is not initialized.
    var numSpeakers: Int {
        guard isInitialized, let tts = tts else { return 0 }
        return Int(SherpaOnnxOfflineTtsNumSpeakers(tts))
    }

    var sampleRate: Int32 {
        guard isInitialized, let tts = tts else { return SherpaTtsEngine.defaultSampleRate }
        return SherpaOnnxOfflineTtsSampleRate(tts)
    }

    // MARK: - Initialize

    func initialize() -> Bool {
        guard !isInitialized else { return true }

        let fm = FileManager.default
        let modelPath = modelDir.appendingPathComponent(onnxModel).path
        let tkPath = modelDir.appendingPathComponent(tokensFile).path
        let voicesPath = modelDir.appendingPathComponent(voicesFile).path
        let lxPath = modelDir.appendingPathComponent(lexiconFile).path
        let dataDir = modelDir.appendingPathComponent(espeakDataDir)

        // Detect model type: Kokoro has voices.bin
        modelType = fm.fileExists(atPath: voicesPath) ? .kokoro : .vits

        // Verify required files based on model type
        let missing: [String]
        switch modelType {
        case .kokoro:
            missing = [modelPath, tkPath, voicesPath].filter { !fm.fileExists(atPath: $0) }
        case .vits:
            missing = [modelPath, tkPath, lxPath].filter { !fm.fileExists(atPath: $0) }
        }
        if !missing.isEmpty {
            os_log(.error, "TTS(%{public}@): missing model files: %{public}@",
                   String(describing: modelType),
                   missing.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
            return false
        }

        let numThreads = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount))
        os_log(.info, "TTS(%{public}@): initializing with numThreads=%d",
               String(describing: modelType), numThreads)

        var config = SherpaOnnxOfflineTtsConfig()
        memset(&config, 0, MemoryLayout<SherpaOnnxOfflineTtsConfig>.size)

        // Track all strdup allocations for cleanup after engine creation
        var allocs: [UnsafeMutablePointer<CChar>?] = []

        let modelPtr = strdup(modelPath); allocs.append(modelPtr)
        let tkPtr = strdup(tkPath); allocs.append(tkPtr)
        let providerPtr = strdup("xnnpack"); allocs.append(providerPtr)

        let dataDirPtr: UnsafeMutablePointer<CChar>? = fm.fileExists(atPath: dataDir.path)
            ? strdup(dataDir.path) : nil
        if let p = dataDirPtr { allocs.append(p) }

        let lxPtr: UnsafeMutablePointer<CChar>? = fm.fileExists(atPath: lxPath)
            ? strdup(lxPath) : nil
        if let p = lxPtr { allocs.append(p) }

        switch modelType {
        case .kokoro:
            let voicesPtr = strdup(voicesPath); allocs.append(voicesPtr)
            config.model.kokoro.model = UnsafePointer(modelPtr!)
            config.model.kokoro.voices = UnsafePointer(voicesPtr!)
            config.model.kokoro.tokens = UnsafePointer(tkPtr!)
            config.model.kokoro.data_dir = dataDirPtr.map { UnsafePointer($0) }
            config.model.kokoro.lexicon = lxPtr.map { UnsafePointer($0) }
            config.model.kokoro.length_scale = 1.0

            // Language hint based on lexicon choice
            if let lx = lxPtr {
                let lxName = URL(fileURLWithPath: lxPath).lastPathComponent.lowercased()
                if lxName.contains("zh") {
                    let langPtr = strdup("zh"); allocs.append(langPtr)
                    config.model.kokoro.lang = UnsafePointer(langPtr!)
                }
            }

            // Rule FSTs for Chinese text normalisation
            let availableFsts = fstFiles
                .map { modelDir.appendingPathComponent($0) }
                .filter { fm.fileExists(atPath: $0.path) }
                .map { $0.path }
            if !availableFsts.isEmpty {
                let joined = availableFsts.joined(separator: ",")
                let fstPtr = strdup(joined); allocs.append(fstPtr)
                config.rule_fsts = UnsafePointer(fstPtr!)
            }

        case .vits:
            config.model.vits.model = UnsafePointer(modelPtr!)
            config.model.vits.tokens = UnsafePointer(tkPtr!)
            config.model.vits.lexicon = UnsafePointer(lxPtr!)
            config.model.vits.data_dir = dataDirPtr.map { UnsafePointer($0) }
        }

        config.model.num_threads = Int32(numThreads)
        config.model.provider = UnsafePointer(providerPtr!)
        config.max_num_sentences = 1  // one sentence at a time for streaming

        tts = SherpaOnnxCreateOfflineTts(&config)

        // Free all strdup'd strings (engine copies internally during creation)
        for ptr in allocs {
            if let p = ptr { free(p) }
        }

        isInitialized = tts != nil

        if isInitialized {
            os_log(.info, "TTS(%{public}@): initialized OK, sample_rate=%d, num_speakers=%d",
                   String(describing: modelType), sampleRate, numSpeakers)
        } else {
            os_log(.error, "TTS(%{public}@): failed to create engine", String(describing: modelType))
        }
        return isInitialized
    }

    // MARK: - Synthesize

    func synthesize(text: String, speed: Float = defaultSpeed, sid: Int = 0) -> [Float]? {
        guard isInitialized, let tts = tts else { return nil }

        os_log(.info, "TTS(%{public}@): synthesizing %d chars, speed=%.2f, sid=%d",
               String(describing: modelType), text.count, speed, sid)

        let startTime = CFAbsoluteTimeGetCurrent()

        var genConfig = SherpaOnnxGenerationConfig()
        memset(&genConfig, 0, MemoryLayout<SherpaOnnxGenerationConfig>.size)
        genConfig.sid = Int32(sid)
        genConfig.speed = speed

        let audio = text.withCString { textPtr in
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
