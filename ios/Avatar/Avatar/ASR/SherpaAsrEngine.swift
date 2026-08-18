//
//  SherpaAsrEngine.swift
//  SiriApp
//
//  Offline ASR engine using sherpa-onnx SenseVoice model.
//  Calls sherpa-onnx C API via bridging header.
//  Ported from Android: SherpaAsrEngine.kt
//

import Foundation
import os.log

class SherpaAsrEngine {
    private let modelDir: URL
    private let modelFile = "model.int8.onnx"
    private let tokensFile = "tokens.txt"

    private var recognizer: OpaquePointer?
    private var sampleBuffer: [Float] = []
    private var isInitialized = false
    private var pendingText = ""

    init(documentsDir: URL) {
        self.modelDir = documentsDir
            .appendingPathComponent("models/asr")
    }

    var isReady: Bool { isInitialized }

    func initialize() -> Bool {
        guard !isInitialized else { return true }

        let modelPath = modelDir.appendingPathComponent(modelFile).path
        let tokensPath = modelDir.appendingPathComponent(tokensFile).path

        let fm = FileManager.default
        guard fm.fileExists(atPath: modelPath) else {
            os_log(.error, "ASR: model file not found: %{public}@", modelPath)
            return false
        }
        guard fm.fileExists(atPath: tokensPath) else {
            os_log(.error, "ASR: tokens file not found: %{public}@", tokensPath)
            return false
        }

        os_log(.info, "ASR: initializing with model=%@", modelPath)

        var config = SherpaOnnxOfflineRecognizerConfig()
        memset(&config, 0, MemoryLayout<SherpaOnnxOfflineRecognizerConfig>.size)

        config.feat_config.sample_rate = 16000
        config.feat_config.feature_dim = 80

        let modelPtr = strdup(modelPath)
        let langPtr = strdup("auto")
        let tokensPtr = strdup(tokensPath)
        let providerPtr = strdup("xnnpack")
        let decodingPtr = strdup("greedy_search")

        config.model_config.sense_voice.model = UnsafePointer(modelPtr)
        config.model_config.sense_voice.language = UnsafePointer(langPtr)
        config.model_config.sense_voice.use_itn = 1
        config.model_config.tokens = UnsafePointer(tokensPtr)
        config.model_config.num_threads = 2  // adaptive: low-end devices use 2
        config.model_config.provider = UnsafePointer(providerPtr)
        config.decoding_method = UnsafePointer(decodingPtr)

        recognizer = SherpaOnnxCreateOfflineRecognizer(&config)

        // Free strdup'd strings
        free(modelPtr)
        free(langPtr)
        free(tokensPtr)
        free(providerPtr)
        free(decodingPtr)

        isInitialized = recognizer != nil

        if isInitialized {
            os_log(.info, "ASR: initialized OK")
        } else {
            os_log(.error, "ASR: failed to create recognizer")
        }
        return isInitialized
    }

    func acceptWaveform(_ samples: [Float]) {
        guard isInitialized else { return }
        sampleBuffer.append(contentsOf: samples)
        // Offline recognizer accumulates samples; decode happens at inputFinished
    }

    func getPendingText() -> String {
        // Offline recognizer doesn't produce partial results
        return ""
    }

    func inputFinished() -> String {
        guard isInitialized, !sampleBuffer.isEmpty, let recognizer = recognizer else {
            sampleBuffer = []
            return ""
        }

        os_log(.info, "ASR: decoding %d samples", sampleBuffer.count)

        let stream = SherpaOnnxCreateOfflineStream(recognizer)
        guard let stream = stream else {
            os_log(.error, "ASR: failed to create offline stream")
            sampleBuffer = []
            return ""
        }

        sampleBuffer.withUnsafeBufferPointer { ptr in
            SherpaOnnxAcceptWaveformOffline(
                stream, 16000, ptr.baseAddress, Int32(sampleBuffer.count)
            )
        }

        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        let result = SherpaOnnxGetOfflineStreamResult(stream)
        let text = result?.pointee.text.map { String(cString: $0) } ?? ""

        SherpaOnnxDestroyOfflineRecognizerResult(result)
        SherpaOnnxDestroyOfflineStream(stream)

        sampleBuffer = []
        os_log(.info, "ASR: result='%@'", text)
        return text
    }

    func destroy() {
        guard isInitialized, let recognizer = recognizer else { return }

        SherpaOnnxDestroyOfflineRecognizer(recognizer)
        self.recognizer = nil
        sampleBuffer = []
        isInitialized = false
        os_log(.info, "ASR: destroyed")
    }
}
