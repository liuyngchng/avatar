//
//  WakeWordEngine.swift
//  SiriApp
//
//  Continuous wake word detection using sherpa-onnx KWS C API.
//  Ported from Android: WakeWordEngine.kt
//

import Foundation
import AVFoundation
import os.log
import os

class WakeWordEngine {

    private enum Config {
        static let sampleRate: Int32 = 16000
        /// 2 × ~40ms buffer at 16kHz ≈ 1280 samples = 80ms per chunk.
        static let bufferSize: AVAudioFrameCount = 1600  // 100ms
        /// RMS energy below this threshold is treated as silence.
        /// 0.0004 = ~-68 dBFS — lowered from 0.0008 to catch quieter speech.
        static let energyThreshold: Float = 0.0004
        /// Hangover buffers after speech energy drops (6 × ~100ms).
        static let energyHangoverBuffers: Int = 6
    }

    // Keywords definition (same as Android: "小爱小爱")
    private let keywordsText = "x iǎo ài x iǎo ài @小爱小爱"

    private var spotterPtr: OpaquePointer?

    private var stateLock = os_unfair_lock()
    private var isRunning = false
    private var detectionThread: Thread?
    private var didStartEngine = false
    private let engine = AVAudioEngine()
    private var cachedConverter: AVAudioConverter?
    private var detectionStream: OpaquePointer?

    var isReady: Bool { spotterPtr != nil }

    // MARK: - Initialization

    func initialize(modelDir: URL, numThreads: Int32 = 1) -> Bool {
        os_unfair_lock_lock(&stateLock)
        defer { os_unfair_lock_unlock(&stateLock) }

        if spotterPtr != nil {
            os_log(.info, "WakeWordEngine: already initialized")
            return true
        }

        let encoderPath = findModelFile(in: modelDir, keyword: "encoder", suffix: ".onnx")
        let decoderPath = findModelFile(in: modelDir, keyword: "decoder", suffix: ".onnx")
        let joinerPath = findModelFile(in: modelDir, keyword: "joiner", suffix: ".onnx")
        let tokensPath = findModelFile(in: modelDir, keyword: "tokens", suffix: ".txt")

        guard let encoder = encoderPath,
              let decoder = decoderPath,
              let joiner = joinerPath,
              let tokens = tokensPath else {
            os_log(.error, "WakeWordEngine: missing model files in %{public}@", modelDir.path)
            return false
        }

        os_log(.info, "WakeWordEngine: encoder=%@, decoder=%@, joiner=%@, tokens=%@",
               encoder, decoder, joiner, tokens)

        var config = SherpaOnnxKeywordSpotterConfig()
        memset(&config, 0, MemoryLayout<SherpaOnnxKeywordSpotterConfig>.size)

        config.feat_config.sample_rate = Config.sampleRate
        config.feat_config.feature_dim = 80

        let encoderPtr = strdup(encoder)
        let decoderPtr = strdup(decoder)
        let joinerPtr = strdup(joiner)
        let tokensPtr = strdup(tokens)
        let providerPtr = strdup("cpu")   // cpu (not xnnpack) per official example
        let keywordsPtr = strdup(keywordsText)

        config.model_config.transducer.encoder = UnsafePointer(encoderPtr)
        config.model_config.transducer.decoder = UnsafePointer(decoderPtr)
        config.model_config.transducer.joiner = UnsafePointer(joinerPtr)
        config.model_config.tokens = UnsafePointer(tokensPtr)
        config.model_config.num_threads = numThreads
        config.model_config.provider = UnsafePointer(providerPtr)
        config.model_config.debug = 0

        config.max_active_paths = 2  // reduced from 4: wake word needs fewer paths
        config.num_trailing_blanks = 30  // explicit: trailing frames before keyword finalisation
        config.keywords_score = 6.0     // increased from 3.0 for stronger keyword bias
        config.keywords_threshold = 0.05
        config.keywords_buf = UnsafePointer(keywordsPtr)
        config.keywords_buf_size = Int32(keywordsText.utf8.count)

        let spotter = SherpaOnnxCreateKeywordSpotter(&config)

        // Free strdup'd strings
        free(encoderPtr)
        free(decoderPtr)
        free(joinerPtr)
        free(tokensPtr)
        free(providerPtr)
        free(keywordsPtr)

        if spotter == nil {
            os_log(.error, "WakeWordEngine: failed to create keyword spotter")
            return false
        }

        spotterPtr = spotter
        os_log(.info, "WakeWordEngine: initialized successfully")
        return true
    }

    // MARK: - Start / Stop

    func start(
        onDetected: @escaping (String) -> Void,
        onError: ((String) -> Void)? = nil
    ) {
        os_unfair_lock_lock(&stateLock)
        guard let spotter = spotterPtr else {
            os_unfair_lock_unlock(&stateLock)
            os_log(.error, "WakeWordEngine: not initialized")
            return
        }
        if isRunning {
            os_unfair_lock_unlock(&stateLock)
            os_log(.info, "WakeWordEngine: already running")
            return
        }
        isRunning = true
        os_unfair_lock_unlock(&stateLock)

        detectionThread = Thread { [weak self] in
            self?.runDetectionLoop(spotter: spotter, onDetected: onDetected, onError: onError)
        }
        detectionThread?.name = "WakeWordDetection"
        detectionThread?.threadPriority = 0.75  // lower than before (was 1.0) to reduce thermal pressure
        detectionThread?.start()
    }

    func stop() {
        os_unfair_lock_lock(&stateLock)
        isRunning = false
        os_unfair_lock_unlock(&stateLock)

        // Stop engine FIRST to halt all tap callbacks. This prevents the
        // tap callback from accessing the KWS stream while the detection
        // thread is destroying it (use-after-free).
        if didStartEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            didStartEngine = false
            cachedConverter = nil
        }

        // Now wait for the detection thread to finish its keep-alive loop.
        let deadline = Date().addingTimeInterval(3.0)
        while true {
            os_unfair_lock_lock(&stateLock)
            let threadDone = detectionThread?.isFinished ?? true
            os_unfair_lock_unlock(&stateLock)
            if threadDone || Date() > deadline { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        os_unfair_lock_lock(&stateLock)
        detectionThread = nil
        os_unfair_lock_unlock(&stateLock)

        // Safe to destroy the stream now — no tap callbacks can be using it.
        if let stream = detectionStream {
            SherpaOnnxDestroyOnlineStream(stream)
            detectionStream = nil
        }
    }

    func destroy() {
        stop()
        // stop() handles engine + stream cleanup; just destroy the spotter
        if let spotter = spotterPtr {
            SherpaOnnxDestroyKeywordSpotter(spotter)
            spotterPtr = nil
            detectionStream = nil
            os_log(.info, "WakeWordEngine: destroyed")
        }
    }

    // MARK: - Detection Loop

    private func runDetectionLoop(
        spotter: OpaquePointer,
        onDetected: @escaping (String) -> Void,
        onError: ((String) -> Void)?
    ) {
        let stream = SherpaOnnxCreateKeywordStream(spotter)
        guard let stream = stream else {
            os_log(.error, "WakeWordEngine: failed to create keyword stream")
            os_unfair_lock_lock(&stateLock)
            isRunning = false
            os_unfair_lock_unlock(&stateLock)
            DispatchQueue.main.async { onError?("Failed to create keyword stream") }
            return
        }
        detectionStream = stream

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Config.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            SherpaOnnxDestroyOnlineStream(stream)
            os_unfair_lock_lock(&stateLock)
            isRunning = false
            os_unfair_lock_unlock(&stateLock)
            DispatchQueue.main.async { onError?("Failed to create audio format") }
            return
        }

        // ── Tap callback state ─────────────────────────────────────
        var hangover = 0
        let outputFormat = recordingFormat
        var bufferCount: Int = 0
        var rmsSum: Float = 0
        var rmsSampleCount: Int = 0
        var fedBuffers: Int = 0       // buffers fed to KWS (past VAD)
        var decodeRounds: Int = 0     // times IsKeywordStreamReady returned true

        // ── Install tap + start engine on MAIN thread ──────────────
        // AVAudioEngine with mic input must be started on the main
        // thread; background-thread start can cause the tap to
        // silently deliver zero/silent buffers on some iOS versions.
        var engineStartFailed = false
        var engineStartErrorMessage: String?

        DispatchQueue.main.sync { [weak self] in
            guard let self = self else { return }

            inputNode.installTap(onBus: 0, bufferSize: Config.bufferSize, format: inputFormat) {
                [weak self] buffer, _ in
                guard let self = self else { return }

                os_unfair_lock_lock(&self.stateLock)
                let running = self.isRunning
                os_unfair_lock_unlock(&self.stateLock)
                if !running { return }

                // Convert to 16kHz mono float32
                let converted: AVAudioPCMBuffer
                if buffer.format.sampleRate == outputFormat.sampleRate
                    && buffer.format.channelCount == outputFormat.channelCount {
                    converted = buffer
                } else {
                    if self.cachedConverter == nil {
                        self.cachedConverter = AVAudioConverter(from: buffer.format, to: outputFormat)
                    }
                    guard let converter = self.cachedConverter,
                          let convertedBuffer = self.convert(buffer: buffer, using: converter) else {
                        return
                    }
                    converted = convertedBuffer
                }

                guard let channelData = converted.floatChannelData else { return }
                let frameLength = Int(converted.frameLength)
                if frameLength <= 0 { return }

                let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

                // ── Diagnostic logging ──────────────────────────
                bufferCount += 1
                let energy = Self.rms(samples)
                rmsSum += energy
                rmsSampleCount += 1

                if bufferCount == 1 {
                    os_log(.info, "WakeWordEngine: tap callback active — first buffer received (RMS=%.6f, threshold=%.6f)",
                           energy, Config.energyThreshold)
                }
                if bufferCount % 50 == 0 {
                    let avgRMS = rmsSum / Float(rmsSampleCount)
                    os_log(.info, "WakeWordEngine: %d buffers received, avg RMS=%.6f, fed=%d decodeRounds=%d",
                           bufferCount, avgRMS, fedBuffers, decodeRounds)
                    rmsSum = 0
                    rmsSampleCount = 0
                }

                // ── Energy-based VAD ────────────────────────────
                if energy >= Config.energyThreshold {
                    hangover = Config.energyHangoverBuffers
                } else if hangover > 0 {
                    hangover -= 1
                } else {
                    return  // skip this buffer (silence)
                }

                // ── Feed to KWS ────────────────────────────────
                guard let stream = self.detectionStream else { return }
                SherpaOnnxOnlineStreamAcceptWaveform(stream, Config.sampleRate, samples, Int32(samples.count))
                fedBuffers += 1

                while SherpaOnnxIsKeywordStreamReady(spotter, stream) != 0 {
                    decodeRounds += 1
                    SherpaOnnxDecodeKeywordStream(spotter, stream)
                    let result = SherpaOnnxGetKeywordResult(spotter, stream)
                    if let result = result {
                        let keyword = (result.pointee.keyword != nil)
                            ? String(cString: result.pointee.keyword)
                            : ""
                        // Log a sample of decode results (every 10th) to see
                        // what tokens the decoder is producing.
                        let tokensStr = (result.pointee.tokens != nil)
                            ? String(cString: result.pointee.tokens)
                            : ""
                        if decodeRounds % 10 == 1 {
                            os_log(.info, "WakeWordEngine: decode #%d — keyword='%{public}@' tokens='%{public}@'",
                                   decodeRounds, keyword, tokensStr)
                        }
                        SherpaOnnxDestroyKeywordResult(result)

                        if !keyword.isEmpty {
                            os_log(.info, "WakeWordEngine: detected '%{public}@'", keyword)
                            SherpaOnnxResetKeywordStream(spotter, stream)
                            DispatchQueue.main.async {
                                onDetected(keyword)
                            }
                        }
                    }
                }
            }

            do {
                engine.prepare()
                try engine.start()
                didStartEngine = true
                os_log(.info, "WakeWordEngine: detection loop started (main thread)")
            } catch {
                engineStartFailed = true
                engineStartErrorMessage = error.localizedDescription
            }
        }

        if engineStartFailed {
            os_log(.error, "WakeWordEngine: failed to start audio engine: %{public}@",
                   engineStartErrorMessage ?? "unknown")
            SherpaOnnxDestroyOnlineStream(stream)
            detectionStream = nil
            didStartEngine = false
            os_unfair_lock_lock(&stateLock)
            isRunning = false
            os_unfair_lock_unlock(&stateLock)
            DispatchQueue.main.async { onError?("Audio engine start failed: \(engineStartErrorMessage ?? "unknown")") }
            return
        }

        // ── Keep-alive loop (background thread) ────────────────────
        // The tap callback does all the work; we just poll isRunning.
        while true {
            os_unfair_lock_lock(&self.stateLock)
            let running = self.isRunning
            os_unfair_lock_unlock(&self.stateLock)
            if !running { break }
            Thread.sleep(forTimeInterval: 0.2)  // 200ms poll
        }

        // NOTE: Do NOT call engine.stop(), removeTap, or destroy the stream here.
        // stop() handles audio teardown and stream destruction after ensuring
        // all tap callbacks have stopped.
        os_log(.info, "WakeWordEngine: detection loop stopped (%d buffers processed)", bufferCount)
    }

    // MARK: - Helpers

    private static func rms(_ samples: [Float]) -> Float {
        var sum: Float = 0
        for s in samples {
            sum += s * s
        }
        return sqrt(sum / Float(samples.count))
    }

    private func convert(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: frameCapacity
        ) else { return nil }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        if let error = error {
            os_log(.error, "WakeWordEngine: audio conversion error: %{public}@", error.localizedDescription)
            return nil
        }
        return outputBuffer
    }

    /// Find a model file in the given directory. Tries short name first, then
    /// scans for a file whose name contains `keyword` and ends with `suffix`.
    private func findModelFile(in dir: URL, keyword: String, suffix: String) -> String? {
        // 1. Try standard short name
        let shortPath = dir.appendingPathComponent("\(keyword)\(suffix)").path
        if FileManager.default.fileExists(atPath: shortPath) {
            return shortPath
        }

        // 2. Scan directory for a matching file
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            if name.contains(keyword) && name.hasSuffix(suffix) {
                return fileURL.path
            }
        }
        return nil
    }
}
