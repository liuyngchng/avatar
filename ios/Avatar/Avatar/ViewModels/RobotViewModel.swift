//
//  RobotViewModel.swift
//  Avatar
//
//  Core orchestrator: FaceDetector → RobotState → ASR → LLM → TTS → AudioPlayer.
//  Ported from Android: MainActivity.kt + Siri MainViewModel.swift
//

import Foundation
import Combine
import os.log
import AVFoundation

@MainActor
class RobotViewModel: ObservableObject {
    @Published var robotState = RobotState()
    @Published var wakeWordEnabled: Bool = false
    @Published var kwsReady: Bool = false
    @Published var enginesReady: Bool = false
    @Published var errorMessage: String?
    @Published var isPaused: Bool = false
    @Published var isInConversation: Bool = false
    @Published var selectedSid: Int = 0
    @Published var ttsNumSpeakers: Int = 0

    private let sidKey = "tts_selected_sid"

    // MARK: - Services

    private let faceDetector = FaceDetector()
    private let audioRecorder = AudioRecorder()
    private let audioPlayer = AudioPlayer()
    private let behaviorEngine = BehaviorEngine()
    private let configRepo = ConfigRepository()
    private let documentsDir: URL

    private lazy var asrEngine: SherpaAsrEngine = {
        SherpaAsrEngine(documentsDir: documentsDir)
    }()
    private lazy var ttsEngine: SherpaTtsEngine = {
        SherpaTtsEngine(documentsDir: documentsDir)
    }()
    private lazy var llmClient = LlmClient(configRepository: configRepo)
    private lazy var chatSession = ChatSession(llmClient: llmClient)

    // Wake word
    private let wakeWordEngine = WakeWordEngine()
    private let wakeWordManager = WakeWordManager.shared
    private var lastWakeTime: Date = .distantPast
    private var wakeWordTriggered = false

    // Multi-turn conversation
    private var isMultiTurn = false
    private var multiTurnBlankCount = 0
    private let maxMultiTurnBlanks = 2   // ~4 s (2 × ~2 s VAD silence per utterance)

    // Recording / TTS tasks
    private var recordingCancellable: AnyCancellable?
    private var faceCancellable: AnyCancellable?
    private var streamingCancellable: AnyCancellable?
    private var speakingTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var blinkTask: Task<Void, Never>?
    private var anticTask: Task<Void, Never>?
    private var wakeEventCancellable: AnyCancellable?
    private var resumeCancellable: AnyCancellable?
    private var wakeRunningCancellable: AnyCancellable?

    // VAD
    private var latestRms: Float = 0
    private var vadTask: Task<Void, Never>?
    private var calibratedNoiseThreshold: Float = 0.012  // calibrated once at startup

    // Pause/resume tracking
    private var isRobotRunning = false
    private var wasWakeWordEnabledBeforePause = false
    private var isInitializingEngines = false
    /// Set to `true` when `onTap()` stops KWS to release the mic — signals
    /// `finishSpeaking()` to resume KWS after the tap-to-talk flow ends.
    private var resumeKwsAfterVoiceFlow = false

    // MARK: - Init

    init() {
        documentsDir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]

        // Observe wake word state
        wakeRunningCancellable = wakeWordManager.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                self?.wakeWordEnabled = running
            }

        // Observe wake word events
        wakeEventCancellable = wakeWordManager.wakeEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.onWakeWordDetected()
            }

        // Observe resume signal
        resumeCancellable = wakeWordManager.resumeSignal
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.onResumeKws()
            }

        // Check KWS model
        kwsReady = ModelManager.checkKwsReady()

        // Audio interruptions
        AudioSessionManager.startObservingInterruptions()
        AudioSessionManager.onInterruptionBegan = { [weak self] in
            Task { @MainActor [weak self] in self?.handleInterruptionBegan() }
        }
        AudioSessionManager.onInterruptionEnded = { [weak self] in
            Task { @MainActor [weak self] in self?.handleInterruptionEnded() }
        }
    }

    // MARK: - Initialization

    func startRobot() {
        guard !isRobotRunning else { return }
        isRobotRunning = true

        // Clear chat history and LLM context on app (re)start
        chatSession.clear()

        initEngines()
        startBlinkTimer()
        startAnticTimer()
    }

    // MARK: - Pause / Resume

    /// Deep-freeze all hardware and background activity (camera, mic, speaker,
    /// wake word, timers, Combine subscriptions). Call when entering settings
    /// or any screen that should take full system resources.
    func pauseRobot() {
        guard isRobotRunning else { return }
        isPaused = true

        // Remember whether KWS was active so we can restore it on resume
        wasWakeWordEnabledBeforePause = wakeWordEnabled

        // Stop all audio (recording, playback, wake word)
        stopAllAudio()

        // Cancel all async tasks
        blinkTask?.cancel()
        blinkTask = nil
        anticTask?.cancel()
        anticTask = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        vadTask?.cancel()
        vadTask = nil
        speakingTask?.cancel()
        speakingTask = nil
        streamingCancellable?.cancel()
        streamingCancellable = nil

        // Reset state to idle
        robotState.mode = .idle
        robotState.isSpeaking = false
        isMultiTurn = false
        multiTurnBlankCount = 0
        isInConversation = false

        // Release audio session so other components (or system) can use it
        AudioSessionManager.deactivate()

        isRobotRunning = false
    }

    /// Thaw everything that was frozen by `pauseRobot()`.
    /// Called when the settings sheet is dismissed and the robot
    /// should resume normal operation.
    func resumeRobot() {
        guard !isRobotRunning else { return }
        isRobotRunning = true
        isPaused = false

        // If engines haven't finished initializing yet (e.g. user opened
        // settings before the async model-loading completed), kick off a
        // new init. initEngines() is safe to call multiple times.
        if !enginesReady {
            initEngines()
        }

        // Restart background timers
        startBlinkTimer()
        startAnticTimer()

        // Restore audio session
        AudioSessionManager.configure()

        // Restart wake word if it was on before the pause
        if wasWakeWordEnabledBeforePause {
            startWakeWordDetection()
        }
    }

    // MARK: - Private: Init helpers

    private func initEngines() {
        guard !isInitializingEngines else { return }
        isInitializingEngines = true

        // Show waking-up state during engine loading (matches Android)
        robotState.mode = .thinking
        robotState.emotion = .sleepy

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            let asrReady = await MainActor.run { self.asrEngine.initialize() }
            let ttsReady = await MainActor.run { self.ttsEngine.initialize() }

            await MainActor.run {
                self.enginesReady = asrReady && ttsReady
                self.robotState.enginesReady = asrReady && ttsReady
                self.isInitializingEngines = false
                if self.enginesReady {
                    self.errorMessage = nil
                    self.robotState.mode = .idle
                    self.robotState.emotion = .neutral
                    // Discover how many speakers the TTS model supports
                    self.ttsNumSpeakers = self.ttsEngine.numSpeakers
                    // Load saved speaker ID, clamp to valid range
                    let saved = UserDefaults.standard.integer(forKey: self.sidKey)
                    self.selectedSid = (self.ttsNumSpeakers > 0) ? min(saved, self.ttsNumSpeakers - 1) : 0
                    // One-time ambient noise calibration for VAD
                    self.calibrateNoiseOnce()
                } else {
                    self.errorMessage = "模型加载失败，请检查模型文件"
                }
            }
        }
    }

    /// Turn on the camera for "looking" mode — triggered by voice command.
    func startLooking() {
        guard enginesReady else {
            errorMessage = "模型未就绪，请先上传模型文件"
            return
        }
        faceDetector.start()
        robotState.mode = .looking
    }

    /// Turn off the camera and return to idle.
    func stopLooking() {
        faceDetector.stop()
        robotState.mode = .idle
    }

    private func startBlinkTimer() {
        blinkTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let delay = UInt64.random(in: 2_000_000_000...5_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
                guard let self = self, !self.isPaused else { continue }
                self.robotState.blinkTrigger += 1
            }
        }
    }

    private func startAnticTimer() {
        anticTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Fire goofy antics every 5-15 seconds when idle
                let delay = UInt64.random(in: 5_000_000_000...15_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
                guard let self = self, !self.isPaused else { continue }
                if self.robotState.mode == .idle {
                    self.robotState.anticTrigger += 1
                }
            }
        }
    }

    /// Stop all in-progress audio: recording, TTS playback, and wake word.
    /// Order matters: cancel subscribers & tasks first (stop consumers),
    /// then tear down hardware engines (stop producers).
    private func stopAllAudio() {
        // 1. Cancel subscribers to stop processing new data
        recordingCancellable?.cancel()
        recordingCancellable = nil

        // 2. Cancel async tasks
        speakingTask?.cancel()
        speakingTask = nil

        // 3. Stop hardware engines (AudioPlayer.stop() sets `terminated`,
        //    which causes any in-flight playSequence callbacks to bail cleanly)
        audioPlayer.stop()
        audioRecorder.stop()

        // 4. Wake word
        wakeWordEngine.stop()
        if wakeWordEnabled {
            wakeWordManager.setRunning(false)
        }
    }

    // MARK: - Interaction (Tap-to-Talk)

    func onTap() {
        guard enginesReady else {
            // Silently ignore taps while engines are loading ("小火正在醒来...");
            // only show an error if initialization completed but failed.
            if !isInitializingEngines {
                errorMessage = "模型加载失败，请检查模型文件"
            }
            return
        }

        // If wake word detection is running, stop it to release the mic
        // before starting recording. Same pattern as the wake-word-triggered
        // flow (handleKwsDetected). We'll resume KWS after the voice flow
        // completes (see finishSpeaking).
        if wakeWordEnabled {
            wakeWordEngine.stop()
            resumeKwsAfterVoiceFlow = true
        }

        if case .listening = robotState.mode {
            stopListening()
        } else if case .speaking = robotState.mode {
            stopSpeaking()
        } else {
            startListening()
        }
    }

    func onLongPress() {
        // Navigate to settings — handled by parent view
    }

    // MARK: - Recording

    /// Calibrate noise threshold once at startup. Records ~1.5s of ambient audio,
    /// computes the minimum RMS energy, and stores a threshold for future VAD.
    func calibrateNoiseOnce() {
        os_log(.info, "RobotVM: starting one-time noise calibration")
        AudioSessionManager.configure()

        let baseSilenceThreshold: Float = 0.012
        let calibrationChunks = 20   // ~1.6s at ~80ms/chunk
        var noiseFloor = Float.greatestFiniteMagnitude
        var chunkCount = 0

        let cancellable = audioRecorder.startRecordingPublisher()
            .sink { [weak self] samples in
                guard let self = self else { return }
                let rms = Self.rms(samples)
                noiseFloor = min(noiseFloor, rms)
                chunkCount += 1
                if chunkCount >= calibrationChunks {
                    self.calibratedNoiseThreshold = max(baseSilenceThreshold, noiseFloor * 1.8)
                    os_log(.info, "RobotVM: noise calibration done — noiseFloor=%.5f threshold=%.5f",
                           noiseFloor, self.calibratedNoiseThreshold)
                    self.audioRecorder.stop()
                }
            }

        // Keep a reference so it doesn't get cancelled before calibration completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [cancellable] in
            _ = cancellable  // retain until timeout
        }
    }

    private func startListening() {
        AudioSessionManager.configure()

        os_log(.info, "RobotVM: start listening")
        robotState.mode = .listening
        robotState.lastUserText = nil
        robotState.responseText = nil

        latestRms = 0
        var silentChunks = 0
        let maxSilentChunks = 25                   // ~2 seconds at ~80ms/chunk
        let maxRecordSeconds: TimeInterval = 10
        let startTime = Date()
        let effectiveThreshold = calibratedNoiseThreshold

        recordingCancellable = audioRecorder.startRecordingPublisher()
            .sink { [weak self] samples in
                guard let self = self else { return }
                self.asrEngine.acceptWaveform(samples)

                // VAD: RMS energy-based silence detection
                let rms = Self.rms(samples)
                self.latestRms = rms

                if rms < effectiveThreshold {
                    silentChunks += 1
                    if silentChunks >= maxSilentChunks {
                        self.audioRecorder.stop()
                    }
                } else {
                    silentChunks = max(0, silentChunks - 1)
                }
            }

        // VAD auto-stop timer (polls for silence trigger OR max duration)
        vadTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self = self, case .listening = self.robotState.mode else { break }
                try? await Task.sleep(nanoseconds: 100_000_000)

                // VAD silence triggered the stop
                if silentChunks >= maxSilentChunks {
                    self.processRecording()
                    break
                }
                // Max duration force-stop
                if Date().timeIntervalSince(startTime) >= maxRecordSeconds {
                    os_log(.info, "RobotVM: max record duration reached, auto-stopping")
                    self.audioRecorder.stop()
                    self.processRecording()
                    break
                }
            }
        }
    }

    private func stopListening() {
        os_log(.info, "RobotVM: stop listening")
        audioRecorder.stop()
        vadTask?.cancel()
        vadTask = nil
        recordingCancellable?.cancel()
        recordingCancellable = nil
        processRecording()
    }

    private func processRecording() {
        robotState.mode = .thinking
        robotState.emotion = .curious

        recognitionTask?.cancel()
        recognitionTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            let text = await MainActor.run { self.asrEngine.inputFinished() }

            await MainActor.run {
                guard !text.isEmpty else {
                    os_log(.info, "RobotVM: ASR returned blank")
                    if self.isMultiTurn {
                        self.multiTurnBlankCount += 1
                        os_log(.info, "RobotVM: multi-turn blank #%d/%d",
                               self.multiTurnBlankCount, self.maxMultiTurnBlanks)
                        if self.multiTurnBlankCount >= self.maxMultiTurnBlanks {
                            self.endMultiTurn()
                        } else {
                            self.speakText("嗯？还在吗？")
                        }
                    } else {
                        self.robotState.mode = .idle
                        if self.wakeWordTriggered {
                            self.wakeWordManager.notifyFalseTrigger()
                            self.wakeWordTriggered = false
                            self.wakeWordManager.notifyVoiceFlowDone()
                        }
                        self.speakText("没听清，请再说一遍")
                    }
                    return
                }

                self.robotState.lastUserText = text
                self.multiTurnBlankCount = 0   // reset silence counter on valid input

                if self.wakeWordTriggered {
                    self.wakeWordManager.notifyProductiveWake()
                }
            }

            // Get response — retry once on LLM failure before falling back
            let hasConfig = await MainActor.run { self.configRepo.hasConfig }
            if hasConfig {
                let reply: String
                do {
                    reply = try await self.chatWithLLM(text)
                } catch {
                    os_log(.error, "RobotVM: LLM attempt 1 failed: %{public}@, retrying...",
                           error.localizedDescription)
                    // One retry after a short delay
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    do {
                        reply = try await self.chatWithLLM(text)
                    } catch {
                        os_log(.error, "RobotVM: LLM attempt 2 failed, falling back to behavior engine")
                        let (fallback, emotion) = await MainActor.run { self.behaviorEngine.respond(text) }
                        await MainActor.run {
                            self.robotState.responseText = fallback
                            self.robotState.emotion = emotion
                            self.speakText(fallback)
                        }
                        return
                    }
                }
                await MainActor.run {
                    self.robotState.responseText = reply
                    self.robotState.emotion = .happy
                    self.speakText(reply)
                }
            } else {
                let (response, emotion) = await MainActor.run { self.behaviorEngine.respond(text) }
                await MainActor.run {
                    self.robotState.responseText = response
                    self.robotState.emotion = emotion
                    self.speakText(response)
                }
            }
        }
    }

    // MARK: - LLM

    private func chatWithLLM(_ text: String) async throws -> String {
        let streamPublisher = chatSession.sendStream(text)

        return try await withCheckedThrowingContinuation { continuation in
            var fullReply = ""

            streamingCancellable = streamPublisher
                .flatMap { $0 }
                .sink(
                    receiveCompletion: { completion in
                        if case .failure(let error) = completion {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: fullReply)
                        }
                    },
                    receiveValue: { token in
                        fullReply += token
                    }
                )
        }
    }

    // MARK: - TTS

    func speakText(_ text: String) {
        // Stop any in-progress speech to prevent overlapping TTS.
        // This ensures behavior-engine greetings don't interrupt LLM
        // responses, and newer user actions always take priority.
        speakingTask?.cancel()
        audioPlayer.stop()

        let prevMode = robotState.mode
        robotState.mode = .speaking
        robotState.isSpeaking = true

        speakingTask = Task { @MainActor [weak self] in
            await self?.speakAndFinish(text, prevMode: prevMode)
        }
    }

    private func speakAndFinish(_ text: String, prevMode: RobotMode) async {
        guard ttsEngine.isReady else {
            finishSpeaking(prevMode: prevMode)
            return
        }

        let sentences = TextNormalizer.splitSentences(text)
        let sr = ttsEngine.sampleRate

        // Synthesize each sentence into a separate chunk.
        // Each chunk is played independently; the playerNode is stopped
        // between chunks to flush residual audio — no bleed.
        let chunks: [[Float]] = await Task.detached(priority: .userInitiated) {
            var results: [[Float]] = []
            for sentence in sentences {
                if Task.isCancelled { break }
                let normalized = TextNormalizer.normalize(sentence)
                guard normalized.isNotBlank else { continue }
                if let pcm = await self.ttsEngine.synthesize(text: normalized, sid: self.selectedSid) {
                    results.append(pcm)
                }
            }
            return results
        }.value

        guard !chunks.isEmpty else {
            finishSpeaking(prevMode: prevMode)
            return
        }

        // playSequence: each chunk scheduled → played → node stopped (flush) → next chunk
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.audioPlayer.playSequence(chunks: chunks, sampleRate: Double(sr)) {
                cont.resume()
            }
        }

        self.audioPlayer.stop()
        self.finishSpeaking(prevMode: prevMode)
    }

    private func finishSpeaking(prevMode: RobotMode) {
        robotState.isSpeaking = false

        if isMultiTurn {
            // Continue multi-turn: auto-listen for next utterance
            robotState.mode = .listening
            startListening()
            return
        }

        robotState.mode = .idle

        if wakeWordTriggered {
            wakeWordTriggered = false
            wakeWordManager.notifyVoiceFlowDone()
        }

        // Resume KWS after a tap-to-talk flow (onTap stops KWS to release
        // the mic, but the wake-word-triggered flag isn't set for taps).
        if resumeKwsAfterVoiceFlow {
            resumeKwsAfterVoiceFlow = false
            onResumeKws()
        }
    }

    func stopSpeaking() {
        speakingTask?.cancel()
        audioPlayer.stop()
        robotState.isSpeaking = false

        // Manual stop during multi-turn: end the conversation
        if isMultiTurn {
            endMultiTurn()
        }

        robotState.mode = .idle

        // Resume KWS if it was stopped by onTap() before this
        if resumeKwsAfterVoiceFlow {
            resumeKwsAfterVoiceFlow = false
            onResumeKws()
        }
    }

    // MARK: - Wake Word

    func toggleWakeWord(_ enable: Bool) {
        if enable {
            startWakeWordDetection()
        } else {
            stopWakeWordDetection()
        }
    }

    private func startWakeWordDetection() {
        kwsReady = ModelManager.checkKwsReady()
        guard kwsReady else {
            errorMessage = "唤醒模型未下载，请在模型管理界面下载"
            return
        }

        let modelDir = ModelManager.kwsModelDirURL()

        if !wakeWordEngine.isReady {
            guard wakeWordEngine.initialize(modelDir: modelDir) else {
                errorMessage = "唤醒引擎初始化失败"
                return
            }
        }

        AudioSessionManager.configureForKws()

        wakeWordEngine.start(
            onDetected: { [weak self] keyword in
                Task { @MainActor in
                    self?.handleKwsDetected(keyword)
                }
            },
            onError: { [weak self] message in
                Task { @MainActor in
                    os_log(.error, "RobotVM: KWS error: %{public}@", message)
                    self?.wakeWordManager.setRunning(false)
                }
            }
        )

        wakeWordManager.setRunning(true)
        os_log(.info, "RobotVM: wake word detection started")
    }

    private func stopWakeWordDetection() {
        wakeWordEngine.stop()
        wakeWordManager.setRunning(false)
        // Restore default audio session to avoid sound routing to earpiece
        AudioSessionManager.configure()
    }

    private func handleKwsDetected(_ keyword: String) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastWakeTime)
        let debounce = wakeWordManager.currentDebounceSec

        if elapsed < debounce {
            os_log(.info, "RobotVM: wake word debounced (%.1fs < %.1fs)", elapsed, debounce)
            return
        }
        lastWakeTime = now

        os_log(.info, "RobotVM: wake word '%{public}@' detected", keyword)

        // Pause KWS engine first, then start voice flow
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            await MainActor.run { self.wakeWordEngine.stop() }
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                guard self.enginesReady else {
                    self.errorMessage = "模型未就绪，请在模型管理界面下载模型"
                    self.onResumeKws()
                    return
                }
                self.wakeWordManager.notifyWakeWord()
            }
        }
    }

    private func onWakeWordDetected() {
        guard enginesReady else { return }
        guard robotState.mode == .idle || robotState.mode == .looking else {
            os_log(.info, "RobotVM: ignoring wake word — not idle/looking")
            return
        }

        wakeWordTriggered = true
        isMultiTurn = true
        multiTurnBlankCount = 0
        isInConversation = true
        os_log(.info, "RobotVM: multi-turn conversation started")

        // TTS "哎，我在呢" then auto-listen
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.robotState.mode = .speaking
            AudioSessionManager.configure()

            if let pcm = await Task.detached(priority: .userInitiated, operation: {
                await self.ttsEngine.synthesize(text: "哎，我在呢", speed: 1.0, sid: self.selectedSid)
            }).value {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    self.audioPlayer.play(pcmFloats: pcm, sampleRate: Double(self.ttsEngine.sampleRate)) {
                        cont.resume()
                    }
                }
                self.audioPlayer.stop()
            }

            self.startListening()
        }
    }

    private func onResumeKws() {
        os_log(.info, "RobotVM: resuming KWS")

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard self.wakeWordEnabled else {
                os_log(.info, "RobotVM: onResumeKws skipped — wake word disabled")
                return
            }

            AudioSessionManager.configureForKws()

            if !self.wakeWordEngine.isReady {
                let modelDir = ModelManager.kwsModelDirURL()
                guard self.wakeWordEngine.initialize(modelDir: modelDir) else { return }
            }
            self.wakeWordEngine.start(
                onDetected: { [weak self] keyword in
                    Task { @MainActor in self?.handleKwsDetected(keyword) }
                },
                onError: { [weak self] message in
                    Task { @MainActor in
                        os_log(.error, "RobotVM: KWS error: %{public}@", message)
                        self?.wakeWordManager.setRunning(false)
                    }
                }
            )
            self.wakeWordManager.setRunning(true)
        }
    }

    private func endMultiTurn() {
        os_log(.info, "RobotVM: ending multi-turn conversation")
        isMultiTurn = false
        multiTurnBlankCount = 0
        isInConversation = false
        wakeWordTriggered = false
        wakeWordManager.notifyVoiceFlowDone()
    }

    // MARK: - Audio Interruptions

    private func handleInterruptionBegan() {
        os_log(.info, "RobotVM: audio interruption began")
        // Cancel subscribers & tasks first (consumers), then stop engines (producers)
        recordingCancellable?.cancel()
        recordingCancellable = nil
        streamingCancellable?.cancel()
        streamingCancellable = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        speakingTask?.cancel()
        speakingTask = nil
        audioPlayer.stop()
        audioRecorder.stop()
        wakeWordEngine.stop()
        wakeWordManager.setRunning(false)
        robotState.mode = .idle
        robotState.isSpeaking = false
    }

    private func handleInterruptionEnded() {
        os_log(.info, "RobotVM: audio interruption ended")
        if wakeWordEnabled {
            onResumeKws()
        }
    }

    // MARK: - Helpers

    func checkConfig() -> Bool {
        let hasConfig = configRepo.hasConfig
        return hasConfig
    }

    func clearError() {
        errorMessage = nil
    }

    /// Change the TTS speaker ID and persist the selection.
    func setSpeaker(_ sid: Int) {
        let clamped = max(0, min(sid, ttsNumSpeakers - 1))
        selectedSid = clamped
        UserDefaults.standard.set(clamped, forKey: sidKey)
    }

    /// Human-readable voice name for the given speaker ID.
    func speakerName(for sid: Int) -> String {
        ttsEngine.speakerName(for: sid)
    }

    private static func rms(_ samples: [Float]) -> Float {
        var sum: Float = 0
        for s in samples {
            sum += s * s
        }
        return sqrt(sum / Float(samples.count))
    }

    deinit {
        faceDetector.stop()
        audioRecorder.stop()
        audioPlayer.stop()
        wakeWordEngine.destroy()
        recordingCancellable?.cancel()
        faceCancellable?.cancel()
        streamingCancellable?.cancel()
        speakingTask?.cancel()
        recognitionTask?.cancel()
        blinkTask?.cancel()
        anticTask?.cancel()
        vadTask?.cancel()
        wakeEventCancellable?.cancel()
        resumeCancellable?.cancel()
        wakeRunningCancellable?.cancel()
    }
}
