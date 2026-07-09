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

    // Recording / TTS tasks
    private var recordingCancellable: AnyCancellable?
    private var faceCancellable: AnyCancellable?
    private var streamingCancellable: AnyCancellable?
    private var speakingTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var blinkTask: Task<Void, Never>?
    private var faceCheckTask: Task<Void, Never>?
    private var wakeEventCancellable: AnyCancellable?
    private var resumeCancellable: AnyCancellable?
    private var wakeRunningCancellable: AnyCancellable?

    // VAD
    private var latestRms: Float = 0
    private var vadTask: Task<Void, Never>?

    // Expression smoothing
    private var expressionWindow: [Emotion?] = []
    private let expressionWindowSize = 5

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
        // Initialize engines
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            let asrReady = await MainActor.run { self.asrEngine.initialize() }
            let ttsReady = await MainActor.run { self.ttsEngine.initialize() }

            await MainActor.run {
                self.enginesReady = asrReady && ttsReady
                if !self.enginesReady {
                    self.errorMessage = "模型加载失败，请检查模型文件"
                }
            }
        }

        // Start face detection
        faceDetector.start()

        // Observe face detection results
        faceCancellable = faceDetector.faces
            .receive(on: DispatchQueue.main)
            .sink { [weak self] result in
                guard let self = self else { return }
                self.robotState.faceTargetX = result?.cx
                self.robotState.faceTargetY = result?.cy
                self.robotState.msSinceLastFace = (result != nil) ? 0 : self.robotState.msSinceLastFace + 200

                // Expression mimicry: in watching mode, mirror the user's
                // facial expression onto the robot. Use a rolling window
                // to smooth out transient Vision noise.
                if let result = result, self.robotState.mode == .watching {
                    let inferred = result.inferredEmotion()
                    self.expressionWindow.append(inferred)
                    if self.expressionWindow.count > self.expressionWindowSize {
                        self.expressionWindow.removeFirst()
                    }
                    // Require majority agreement in the window
                    if let dominant = self.smoothedExpression() {
                        self.robotState.emotion = dominant
                    }
                }
            }

        // Start idle wander blink timer
        blinkTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let delay = UInt64.random(in: 2_000_000_000...5_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
                guard let self = self, !self.isPaused else { continue }
                self.robotState.blinkTrigger += 1
            }
        }

        // Face presence → mode transitions
        faceCheckTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms poll

                guard let self = self, !self.isPaused else { continue }
                let hasFace = self.robotState.faceTargetX != nil
                let idleTooLong = self.robotState.msSinceLastFace > 10_000

                // Face appeared → WATCHING + greeting
                if hasFace && self.robotState.mode == .idle {
                    let greeting = self.behaviorEngine.onFaceAppear()
                    self.robotState.mode = .watching
                    self.robotState.emotion = .happy
                    self.robotState.responseText = greeting
                    self.expressionWindow.removeAll()   // fresh expression window
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    self.speakText(greeting)
                }

                // Face disappeared too long → IDLE + remark
                if !hasFace
                    && idleTooLong
                    && self.robotState.mode != .idle
                    && self.robotState.mode != .listening
                    && self.robotState.mode != .speaking {
                    let remark = self.behaviorEngine.onFaceDisappear()
                    self.robotState.mode = .idle
                    if let remark = remark {
                        self.speakText(remark)
                    }
                }
            }
        }
    }

    // MARK: - Interaction (Tap-to-Talk)

    func onTap() {
        guard enginesReady else {
            errorMessage = "模型未就绪，请先上传模型文件"
            return
        }

        // If wake word detection is running, stop it to release the mic
        // before starting recording. Same pattern as the wake-word-triggered
        // flow (handleKwsDetected).
        if wakeWordEnabled {
            wakeWordEngine.stop()
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

    private func startListening() {
        AudioSessionManager.configure()

        os_log(.info, "RobotVM: start listening")
        robotState.mode = .listening
        robotState.lastUserText = nil
        robotState.responseText = nil

        latestRms = 0
        var silentChunks = 0
        let silenceThreshold: Float = 0.012   // RMS below this = silence
        let maxSilentChunks = 25               // ~2 seconds at ~80ms/chunk
        let maxRecordSeconds: TimeInterval = 10
        let startTime = Date()

        recordingCancellable = audioRecorder.startRecordingPublisher()
            .sink { [weak self] samples in
                guard let self = self else { return }
                self.asrEngine.acceptWaveform(samples)

                // VAD: RMS energy-based silence detection
                let rms = Self.rms(samples)
                self.latestRms = rms

                if rms < silenceThreshold {
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
                    self.robotState.mode = self.robotState.faceTargetX != nil ? .watching : .idle
                    if self.wakeWordTriggered {
                        self.wakeWordManager.notifyFalseTrigger()
                        self.wakeWordTriggered = false
                        self.wakeWordManager.notifyVoiceFlowDone()
                    }
                    self.speakText("没听清，请再说一遍")
                    return
                }

                self.robotState.lastUserText = text

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
                            self.robotState.mode = .speaking
                            self.robotState.emotion = emotion
                            self.robotState.isSpeaking = true
                        }
                        // Skip the success path below
                        if let responseText = await MainActor.run(body: { self.robotState.responseText }) {
                            await self.speakAndFinish(responseText, prevMode: .thinking)
                        }
                        return
                    }
                }
                await MainActor.run {
                    self.robotState.responseText = reply
                    self.robotState.mode = .speaking
                    self.robotState.emotion = .happy
                    self.robotState.isSpeaking = true
                }
            } else {
                let (response, emotion) = await MainActor.run { self.behaviorEngine.respond(text) }
                await MainActor.run {
                    self.robotState.responseText = response
                    self.robotState.mode = .speaking
                    self.robotState.emotion = emotion
                    self.robotState.isSpeaking = true
                }
            }

            // Speak the response
            if let responseText = await MainActor.run(body: { self.robotState.responseText }) {
                await self.speakAndFinish(responseText, prevMode: .thinking)
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
                if let pcm = await self.ttsEngine.synthesize(text: normalized) {
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
        let newMode: RobotMode = (robotState.faceTargetX != nil) ? .watching : .idle
        robotState.mode = newMode
        if newMode == .watching {
            expressionWindow.removeAll()
        }

        if wakeWordTriggered {
            wakeWordTriggered = false
            wakeWordManager.notifyVoiceFlowDone()
        }
    }

    func stopSpeaking() {
        speakingTask?.cancel()
        audioPlayer.stop()
        robotState.isSpeaking = false
        let newMode: RobotMode = (robotState.faceTargetX != nil) ? .watching : .idle
        robotState.mode = newMode
        if newMode == .watching {
            expressionWindow.removeAll()
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
        guard robotState.mode == .idle || robotState.mode == .watching else {
            os_log(.info, "RobotVM: ignoring wake word — not idle/watching")
            return
        }

        wakeWordTriggered = true

        // TTS "哎，我在呢" then auto-listen
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.robotState.mode = .speaking
            AudioSessionManager.configure()

            if let pcm = await Task.detached(priority: .userInitiated, operation: {
                await self.ttsEngine.synthesize(text: "哎，我在呢", speed: 1.0)
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
        guard wakeWordEnabled else { return }
        os_log(.info, "RobotVM: resuming KWS")

        AudioSessionManager.configureForKws()

        Task { @MainActor [weak self] in
            guard let self = self else { return }
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

    // MARK: - Audio Interruptions

    private func handleInterruptionBegan() {
        os_log(.info, "RobotVM: audio interruption began")
        audioRecorder.stop()
        recordingCancellable?.cancel()
        recordingCancellable = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        streamingCancellable?.cancel()
        streamingCancellable = nil
        speakingTask?.cancel()
        speakingTask = nil
        audioPlayer.stop()
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

    /// Returns the emotion that appears most often in the expression window,
    /// or nil when there's no clear consensus.
    private func smoothedExpression() -> Emotion? {
        let recent = expressionWindow
        guard !recent.isEmpty else { return nil }

        var counts: [Emotion: Int] = [:]
        for e in recent {
            guard let e = e else { continue }
            counts[e, default: 0] += 1
        }
        guard let best = counts.max(by: { $0.value < $1.value }) else { return nil }

        // Require ≥ 60% of the window to agree
        let threshold = max(1, Int(Double(expressionWindowSize) * 0.6))
        return best.value >= threshold ? best.key : nil
    }

    func checkConfig() -> Bool {
        let hasConfig = configRepo.hasConfig
        return hasConfig
    }

    func clearError() {
        errorMessage = nil
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
        faceCheckTask?.cancel()
        vadTask?.cancel()
        wakeEventCancellable?.cancel()
        resumeCancellable?.cancel()
        wakeRunningCancellable?.cancel()
    }
}
