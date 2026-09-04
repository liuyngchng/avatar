package com.rd.avatar

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.SystemClock
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.*
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import com.rd.avatar.robot.BehaviorEngine
import com.rd.avatar.robot.Emotion
import com.rd.avatar.robot.RobotMode
import com.rd.avatar.robot.RobotState
import com.rd.avatar.robot.VisemeGenerator
import com.rd.avatar.ui.VrmController
import com.rd.avatar.ui.VrmFaceScreen
import android.util.Log
import com.rd.avatar.asr.SherpaAsrEngine
import com.rd.avatar.audio.AudioPlayer
import com.rd.avatar.audio.AudioRecorder
import com.rd.avatar.audio.VoiceService
import com.rd.avatar.audio.WakeWordManager
import com.rd.avatar.chat.ChatSession
import com.rd.avatar.chat.LlmClient
import com.rd.avatar.config.ConfigHttpServer
import com.rd.avatar.config.ConfigRepository
import com.rd.avatar.config.ConfigViewModel
import com.rd.avatar.model.ModelManager
import com.rd.avatar.tts.SherpaTtsEngine
import com.rd.avatar.tts.TextNormalizer
import com.rd.avatar.ui.ModelSetupScreen
import com.rd.avatar.ui.SettingsHubScreen
import com.rd.avatar.ui.SettingsScreen
import com.rd.avatar.ui.TextReaderScreen
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlin.random.Random

/** Navigation destinations for the settings stack. */
private sealed class Screen {
    object RobotFace : Screen()
    object SettingsHub : Screen()
    object LlmConfig : Screen()
    object ModelSetup : Screen()
    object TextReader : Screen()
}

class MainActivity : ComponentActivity() {

    private val behaviorEngine = BehaviorEngine()

    // VRM controller — bridges Kotlin ↔ the VRM WebView.
    private val vrmController by lazy { VrmController(onTap = {}) }

    // Sherpa-onnx engines (offline)
    private val asrEngine by lazy { SherpaAsrEngine(this) }
    private val ttsEngine by lazy { SherpaTtsEngine(this) }
    private val audioPlayer = AudioPlayer(this)
    private val audioRecorder = AudioRecorder(this)

    @Volatile private var asrReady = false
    @Volatile private var ttsReady = false
    @Volatile private var isRecording = false
    @Volatile private var recordingJob: Job? = null
    @Volatile private var onSpeechEnd: ((String?) -> Unit)? = null
    @Volatile private var lastSpeechChunkCount = 0
    @Volatile private var recordingGeneration = 0
    // While > now, mic audio is dropped — used while the wake greeting plays
    // so its echo never reaches the ASR or trips the VAD.
    @Volatile private var suppressRecordUntil = 0L
    // True when the current conversation was started by the wake word (not tap).
    @Volatile private var conversationStartedByWake = false
    // The job currently playing a reply — cancelled for tap-to-interrupt.
    @Volatile private var currentSpeakJob: Job? = null

    // Lifecycle-aware scope
    private val activityScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    // VAD constants
    companion object {
        private const val VAD_SILENCE_THRESHOLD = 0.022f
        // 12 × ~80ms ≈ 1s of trailing silence ends the turn (was 20 → ~3.2s
        // with the old 4× recorder buffers, which felt like the robot was deaf).
        private const val VAD_MAX_SILENT_CHUNKS = 12
        private const val NOISE_CALIBRATION_CHUNKS = 20
        private const val MAX_RECORD_SECONDS = 10f
        // Multi-turn conversation: if no one speaks within this time, go to sleep.
        private const val CONVERSATION_TIMEOUT_MS = 30_000L
    }

    private var calibratedNoiseThreshold: Float = VAD_SILENCE_THRESHOLD

    // LLM
    private val configRepository by lazy { ConfigRepository(this) }
    private val configHttpServer by lazy { ConfigHttpServer(configRepository) }
    private val llmClient by lazy { LlmClient(configRepository) }
    private val chatSession by lazy { ChatSession(llmClient) }
    private var llmConfigured = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        chatSession.clear()
        llmConfigured = configRepository.hasConfig
        Log.i("MainActivity", "LLM configured: $llmConfigured")

        setContent {
            var robotState by remember { mutableStateOf(RobotState()) }
            var hasAudioPermission by remember { mutableStateOf(checkAudioPermission()) }
            var enginesReady by remember { mutableStateOf(false) }

            val modelsReady = ModelManager.checkAsrReady(this) &&
                ModelManager.checkTtsReady(this)
            var currentScreen by remember {
                mutableStateOf<Screen>(if (modelsReady) Screen.RobotFace else Screen.ModelSetup)
            }

            val scope = rememberCoroutineScope()
            // Wake word is a persisted system config, independent of conversation state.
            // The service runs continuously when enabled; conversations only pause/resume KWS.
            var wakeWordEnabled by remember {
                mutableStateOf(configRepository.wakeWordEnabled)
            }

            // ─── Conversation state ────────────────────────────────────
            // True when the user is in an active conversation (tap or wake word).
            var conversationActive by remember { mutableStateOf(false) }
            // Timeout job: fires after CONVERSATION_TIMEOUT_MS of silence,
            // ending the conversation and returning to idle.
            var conversationTimeoutJob by remember { mutableStateOf<Job?>(null) }

            /** Reset the 30s no-speech timeout. */
            fun resetConversationTimeout() {
                conversationTimeoutJob?.cancel()
                conversationTimeoutJob = scope.launch {
                    delay(CONVERSATION_TIMEOUT_MS)
                    Log.i("MainActivity", "Conversation timeout (${CONVERSATION_TIMEOUT_MS}ms) — going to sleep")
                    conversationActive = false
                    conversationStartedByWake = false
                    stopRecording { } // stop any in-progress recording
                    WakeWordManager.notifyVoiceFlowDone()
                    audioPlayer.stop()
                    robotState = robotState.copy(mode = RobotMode.IDLE, isSpeaking = false, responseText = null)
                }
            }

            /** End the conversation and return to idle. */
            fun endConversation() {
                conversationActive = false
                conversationStartedByWake = false
                conversationTimeoutJob?.cancel()
                conversationTimeoutJob = null
                WakeWordManager.notifyVoiceFlowDone()
                robotState = robotState.copy(mode = RobotMode.IDLE, isSpeaking = false, responseText = null)
            }

            // ─── Speech result handler ─────────────────────────────────
            var onSpeechResult: ((String?) -> Unit)? = null

            /** After a reply finishes: brief cooldown, then auto-listen (or idle). */
            fun afterSpeaking() {
                if (conversationActive) {
                    scope.launch {
                        delay(300)  // short cooldown so the reply's reverb dies out
                        robotState = robotState.copy(
                            mode = RobotMode.LISTENING, isSpeaking = false, responseText = null
                        )
                        startRecording(onSpeechResult!!)
                    }
                } else {
                    robotState = robotState.copy(mode = RobotMode.IDLE, isSpeaking = false, responseText = null)
                }
            }

            /**
             * Speak a reply to [userText]: stream the LLM response, synthesize
             * sentence by sentence, and play each sentence while the next one
             * synthesizes (pipelined). The subtitle grows sentence by sentence.
             * Falls back to the rule engine when the LLM is unavailable/fails.
             * Cancelled by tap-to-interrupt via [currentSpeakJob].
             */
            suspend fun speakReply(userText: String, onDone: () -> Unit) {
                if (!configRepository.hasConfig) {
                    val (response, emotion) = behaviorEngine.respond(userText)
                    robotState = robotState.copy(
                        mode = RobotMode.SPEAKING, responseText = response,
                        emotion = emotion, isSpeaking = true
                    )
                    speak(response, onDone)
                    return
                }

                val streamResult = chatSession.sendStream(userText)
                if (streamResult.isFailure) {
                    Log.w("MainActivity", "LLM stream setup failed, falling back to rules",
                        streamResult.exceptionOrNull())
                    val (response, emotion) = behaviorEngine.respond(userText)
                    robotState = robotState.copy(
                        mode = RobotMode.SPEAKING, responseText = response,
                        emotion = emotion, isSpeaking = true
                    )
                    speak(response, onDone)
                    return
                }

                val flow = streamResult.getOrThrow()
                val sr = ttsEngine.getSampleRate()
                val queue = Channel<SpeechChunk>(capacity = 2)

                // Producer: stream text → complete sentences → synthesized PCM.
                // Runs ahead of playback so the next sentence is ready in time.
                val producer = scope.launch(Dispatchers.IO) {
                    var acc = ""
                    try {
                        flow.collect { delta ->
                            acc += delta
                            val (complete, rest) = TextNormalizer.extractCompleteSentences(acc)
                            if (complete.isNotEmpty()) {
                                acc = rest
                                for (sentence in complete) {
                                    val normalized = TextNormalizer.normalize(sentence)
                                    if (normalized.isBlank()) continue
                                    val pcm = ttsEngine.synthesize(normalized)
                                    if (pcm != null) queue.send(SpeechChunk(pcm, sentence))
                                }
                            }
                        }
                        // Stream finished — flush whatever remains.
                        val last = acc.trim()
                        if (last.isNotBlank()) {
                            val normalized = TextNormalizer.normalize(last)
                            if (normalized.isNotBlank()) {
                                val pcm = ttsEngine.synthesize(normalized)
                                if (pcm != null) queue.send(SpeechChunk(pcm, last))
                            }
                        }
                    } catch (e: Exception) {
                        Log.w("MainActivity", "LLM stream error, speaking what arrived", e)
                    } finally {
                        queue.close()
                    }
                }

                // Consumer: play sentences in order; the subtitle shows the
                // text spoken so far (progressive, not the whole reply at once).
                val spokenText = StringBuilder()
                var spoken = false
                try {
                    for (chunk in queue) {
                        spokenText.append(chunk.text)
                        if (!spoken) {
                            spoken = true
                            robotState = robotState.copy(
                                mode = RobotMode.SPEAKING, emotion = Emotion.HAPPY, isSpeaking = true
                            )
                        }
                        robotState = robotState.copy(responseText = spokenText.toString())
                        val durationMs = (chunk.pcm.size.toLong() * 1000 / sr).toInt()
                        val timeline = VisemeGenerator.generateVisemeTimeline(chunk.text, durationMs)
                        if (timeline != null) {
                            vrmController.sendVisemeTimeline(timeline)
                        }
                        audioPlayer.play(chunk.pcm, sr)
                    }
                } catch (e: CancellationException) {
                    throw e  // tap-to-interrupt: finally below persists partial text
                } catch (e: Exception) {
                    Log.w("MainActivity", "Playback error, ending turn", e)
                } finally {
                    producer.cancel()
                    // Persist whatever was actually delivered (partial on interrupt).
                    if (spokenText.isNotEmpty()) {
                        chatSession.appendAssistantReply(spokenText.toString())
                    }
                }

                if (spoken) {
                    onDone()
                } else {
                    // Stream produced nothing usable — fall back to rules.
                    val (response, emotion) = behaviorEngine.respond(userText)
                    robotState = robotState.copy(
                        mode = RobotMode.SPEAKING, responseText = response,
                        emotion = emotion, isSpeaking = true
                    )
                    speak(response, onDone)
                }
            }

            onSpeechResult = onResult@ { text ->
                // Minimum-speech gate: filter out echo/reverb.
                val minSpeechChunks = 6  // ~500ms at ~80ms/buffer
                if (lastSpeechChunkCount < minSpeechChunks) {
                    Log.i("MainActivity",
                        "Utterance too short (${lastSpeechChunkCount} chunks < $minSpeechChunks), treating as echo")
                    if (conversationStartedByWake) {
                        conversationStartedByWake = false
                        WakeWordManager.notifyFalseTrigger()
                    }
                    if (conversationActive) {
                        // Still in conversation — go back to listening.
                        robotState = robotState.copy(
                            mode = RobotMode.LISTENING, isSpeaking = false, responseText = null
                        )
                        startRecording(onSpeechResult!!)
                    }
                    return@onResult
                }

                if (text != null && text.isNotBlank()) {
                    resetConversationTimeout()
                    if (conversationStartedByWake) {
                        conversationStartedByWake = false
                        WakeWordManager.notifyProductiveWake()
                    }
                    // Show what was heard while thinking (subtitle feedback),
                    // then swap to the reply as it streams in.
                    robotState = robotState.copy(
                        mode = RobotMode.THINKING,
                        lastUserText = text,
                        responseText = text,
                        emotion = Emotion.CURIOUS,
                        isSpeaking = false
                    )
                    currentSpeakJob = scope.launch {
                        speakReply(text) { afterSpeaking() }
                    }
                } else {
                    // Blank / empty speech
                    if (conversationStartedByWake) {
                        conversationStartedByWake = false
                        WakeWordManager.notifyFalseTrigger()
                    }
                    if (conversationActive) {
                        // Go back to listening — timeout will fire if user stays silent.
                        robotState = robotState.copy(
                            mode = RobotMode.LISTENING, isSpeaking = false, responseText = null
                        )
                        startRecording(onSpeechResult!!)
                    } else {
                        robotState = robotState.copy(mode = RobotMode.IDLE, responseText = null)
                    }
                }
            }

            // ─── Initialize ASR/TTS ────────────────────────────────────
            // Track detailed loading status for the user.
            var loadingStatus by remember { mutableStateOf("") }
            var vrmReady by remember { mutableStateOf(false) }

            LaunchedEffect(modelsReady) {
                if (modelsReady && !asrReady) {
                    robotState = robotState.copy(mode = RobotMode.THINKING, emotion = Emotion.SLEEPY)
                    loadingStatus = "加载 ASR 模型"
                    withContext(Dispatchers.IO) {
                        asrReady = asrEngine.initialize()
                    }
                    if (asrReady) {
                        loadingStatus = "加载 TTS 模型"
                        withContext(Dispatchers.IO) {
                            ttsReady = ttsEngine.initialize()
                        }
                    }
                    // Noise calibration runs in background.
                    calibrateNoiseOnce()
                    // ASR + TTS are ready. VRM loads in the WebView.
                    enginesReady = true
                    robotState = robotState.copy(mode = RobotMode.IDLE, emotion = Emotion.NEUTRAL)
                } else if (asrReady && ttsReady) {
                    enginesReady = true
                }
            }

            // Clear loading overlay when ASR + TTS + VRM are all ready.
            LaunchedEffect(enginesReady, vrmReady) {
                if (enginesReady && vrmReady) {
                    loadingStatus = ""
                }
            }

            // Audio permission
            val audioPermissionLauncher = rememberLauncherForActivityResult(
                ActivityResultContracts.RequestPermission()
            ) { granted -> hasAudioPermission = granted }

            // ─── Blink timer ───
            LaunchedEffect(Unit) {
                while (isActive) {
                    delay(Random.nextLong(2000, 5000))
                    robotState = robotState.copy(blinkTrigger = robotState.blinkTrigger + 1)
                }
            }

            // ─── Random antic timer (idle expressions) ───
            LaunchedEffect(Unit) {
                while (isActive) {
                    delay(Random.nextLong(6000, 15000))
                    if (robotState.mode == RobotMode.IDLE) {
                        robotState = robotState.copy(
                            anticTrigger = robotState.anticTrigger + 1,
                            emotion = Emotion.GOOFY
                        )
                        delay(3000)
                        if (robotState.mode == RobotMode.IDLE && robotState.emotion == Emotion.GOOFY) {
                            robotState = robotState.copy(emotion = Emotion.NEUTRAL)
                        }
                    }
                }
            }

            // ─── Random goofy remarks during idle ───
            LaunchedEffect(robotState.mode) {
                if (robotState.mode == RobotMode.IDLE) {
                    delay(Random.nextLong(15000, 30000))
                    if (robotState.mode == RobotMode.IDLE && robotState.anticTrigger > 0 && robotState.anticTrigger % 3 == 0L) {
                        val remark = behaviorEngine.randomAntic()
                        if (remark != null) {
                            robotState = robotState.copy(
                                mode = RobotMode.SPEAKING, responseText = remark, isSpeaking = true
                            )
                            speak(remark) {
                                robotState = robotState.copy(mode = RobotMode.IDLE, isSpeaking = false, responseText = null)
                            }
                        }
                    }
                }
            }

            // Request audio permission on first launch
            LaunchedEffect(Unit) {
                if (!hasAudioPermission) {
                    audioPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                }
            }

            // Auto-start wake word service if the user had it enabled previously.
            LaunchedEffect(Unit) {
                if (wakeWordEnabled) {
                    startWakeWordService()
                }
            }

            // ─── Wake word event → start conversation ────────────────
            LaunchedEffect(Unit) {
                WakeWordManager.wakeEvents.collect {
                    if (!enginesReady) return@collect
                    if (conversationActive) {
                        Log.i("MainActivity", "Ignoring wake word — already in conversation")
                        return@collect
                    }
                    if (robotState.mode != RobotMode.IDLE) {
                        Log.i("MainActivity", "Ignoring wake word — not idle")
                        return@collect
                    }
                    Log.i("MainActivity", "Wake word triggered — starting conversation")

                    conversationActive = true
                    conversationStartedByWake = true
                    resetConversationTimeout()
                    // Pause KWS so ASR can use the mic. VoiceService stays alive
                    // and will resume KWS when the conversation ends.
                    WakeWordManager.notifyPause()

                    // Listen IMMEDIATELY — the user's first words after the
                    // wake word must not be lost to greeting synthesis.
                    robotState = robotState.copy(
                        mode = RobotMode.LISTENING, isSpeaking = false, responseText = null
                    )
                    startRecording(onSpeechResult)

                    // Greeting plays as a concurrent overlay; the mic stays open.
                    scope.launch {
                        val greetingPcm = withContext(Dispatchers.IO) {
                            ttsEngine.synthesize("哎，我在呢")
                        }
                        if (greetingPcm != null) {
                            val sr = ttsEngine.getSampleRate()
                            val greetingDurMs = (greetingPcm.size.toLong() * 1000 / sr).toInt()
                            // Drop mic audio while the greeting plays (+ a small
                            // tail) so its echo never reaches the ASR or VAD.
                            suppressRecordUntil =
                                SystemClock.elapsedRealtime() + greetingDurMs + 250L
                            val timeline = VisemeGenerator.generateVisemeTimeline("哎，我在呢", greetingDurMs)
                            if (timeline != null) {
                                vrmController.sendVisemeTimeline(timeline)
                            }
                            withContext(Dispatchers.IO) {
                                audioPlayer.play(greetingPcm, sr)
                            }
                        }
                    }
                }
            }

            // ─── Screen routing ────────────────────────────────────────
            when (currentScreen) {
                is Screen.RobotFace -> {
                    VrmFaceScreen(
                        state = robotState,
                        controller = vrmController,
                        loadingStatus = loadingStatus,
                        vrmReady = vrmReady,
                        onVrmReady = { vrmReady = true },
                        onTap = {
                            if (!hasAudioPermission) {
                                audioPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                                return@VrmFaceScreen
                            }
                            if (!enginesReady) {
                                return@VrmFaceScreen
                            }

                            when (robotState.mode) {
                                RobotMode.LISTENING -> {
                                    // Stop recording, process captured speech.
                                    stopRecording { onSpeechResult(it) }
                                }
                                RobotMode.SPEAKING -> {
                                    // Stop TTS and cancel the whole reply pipeline
                                    // (otherwise remaining queued sentences keep playing).
                                    currentSpeakJob?.cancel()
                                    audioPlayer.stop()
                                    if (conversationActive) {
                                        // Still in conversation — go to listening.
                                        scope.launch {
                                            delay(300)
                                            robotState = robotState.copy(
                                                mode = RobotMode.LISTENING, isSpeaking = false, responseText = null
                                            )
                                            startRecording(onSpeechResult)
                                        }
                                        robotState = robotState.copy(isSpeaking = false)
                                    } else {
                                        endConversation()
                                    }
                                }
                                RobotMode.THINKING -> {
                                    // Tapping during thinking does nothing.
                                }
                                else -> {
                                    // Idle — start conversation.
                                    if (wakeWordEnabled) {
                                        // Pause KWS (not kill service) so ASR can use the mic.
                                        WakeWordManager.notifyPause()
                                    }
                                    conversationActive = true
                                    resetConversationTimeout()
                                    startRecording { onSpeechResult(it) }
                                    robotState = robotState.copy(
                                        mode = RobotMode.LISTENING, responseText = null
                                    )
                                }
                            }
                        },
                        onSettingsClick = {
                            currentScreen = Screen.SettingsHub
                        },
                        wakeWordEnabled = wakeWordEnabled,
                        onToggleWakeWord = {
                            val newState = !wakeWordEnabled
                            configRepository.wakeWordEnabled = newState
                            wakeWordEnabled = newState
                            if (newState) {
                                startWakeWordService()
                            } else {
                                stopWakeWordService()
                            }
                        },
                        enginesReady = enginesReady,
                    )
                }

                is Screen.SettingsHub -> {
                    SettingsHubScreen(
                        onNavigateToLlmConfig = { currentScreen = Screen.LlmConfig },
                        onNavigateToModelSetup = { currentScreen = Screen.ModelSetup },
                        onNavigateToTextReader = { currentScreen = Screen.TextReader },
                        onDismiss = { currentScreen = Screen.RobotFace },
                        wakeWordEnabled = wakeWordEnabled,
                        onToggleWakeWord = { enabled ->
                            configRepository.wakeWordEnabled = enabled
                            wakeWordEnabled = enabled
                            if (enabled) startWakeWordService() else stopWakeWordService()
                        },
                        httpServer = configHttpServer,
                    )
                }

                is Screen.LlmConfig -> {
                    val configViewModel: ConfigViewModel = viewModel()
                    SettingsScreen(
                        viewModel = configViewModel,
                        onBack = { currentScreen = Screen.SettingsHub }
                    )
                }

                is Screen.ModelSetup -> {
                    ModelSetupScreen(
                        onBack = { currentScreen = Screen.SettingsHub }
                    )
                }

                is Screen.TextReader -> {
                    TextReaderScreen(
                        onBack = { currentScreen = Screen.SettingsHub },
                        onRead = { text ->
                            robotState = robotState.copy(
                                mode = RobotMode.SPEAKING, responseText = text, isSpeaking = true
                            )
                            speak(text) {
                                robotState = robotState.copy(mode = RobotMode.IDLE, isSpeaking = false, responseText = null)
                            }
                        }
                    )
                }
            }
        }
    }

    override fun onDestroy() {
        activityScope.cancel()
        super.onDestroy()
    }

    // ── Wake word service ──────────────────────────────────────────────

    private fun startWakeWordService() {
        if (!ModelManager.checkKwsReady(this)) return
        val intent = Intent(this, VoiceService::class.java).apply {
            action = VoiceService.ACTION_START
        }
        ContextCompat.startForegroundService(this, intent)
    }

    private fun stopWakeWordService() {
        val intent = Intent(this, VoiceService::class.java).apply {
            action = VoiceService.ACTION_STOP
        }
        stopService(intent)
    }

    // ── ASR recording ─────────────────────────────────────────────────

    private fun calibrateNoiseOnce() {
        Log.i("MainActivity", "Starting one-time noise calibration")
        activityScope.launch(Dispatchers.IO) {
            try {
                var noiseFloor = Float.MAX_VALUE
                var chunkCount = 0
                val job = launch {
                    audioRecorder.startRecording().collect { samples ->
                        var sumSq = 0f
                        for (s in samples) sumSq += s * s
                        val rms = kotlin.math.sqrt(sumSq / samples.size)
                        noiseFloor = minOf(noiseFloor, rms)
                        chunkCount++
                        if (chunkCount >= NOISE_CALIBRATION_CHUNKS) {
                            calibratedNoiseThreshold = maxOf(VAD_SILENCE_THRESHOLD, noiseFloor * 1.8f)
                            Log.i("MainActivity",
                                "Noise calibration done: noiseFloor=${"%.4f".format(noiseFloor)}, " +
                                "threshold=${"%.4f".format(calibratedNoiseThreshold)}")
                            audioRecorder.stopRecording()
                            cancel()
                        }
                    }
                }
                delay(3000)
                job.cancel()
            } catch (_: Exception) {
                Log.w("MainActivity", "Noise calibration failed, using default threshold")
            }
        }
    }

    private fun startRecording(onResult: (String?) -> Unit) {
        if (!asrReady) return

        val myGeneration = ++recordingGeneration
        isRecording = true
        onSpeechEnd = onResult
        var silentChunks = 0
        var warmupBuffers = 2  // ~160ms: skip the mic ramp click without eating real speech
        var speechChunkCount = 0
        val effectiveThreshold = calibratedNoiseThreshold

        recordingJob?.cancel()
        recordingJob = activityScope.launch(Dispatchers.IO) {
            try {
                if (asrReady) {
                    try { asrEngine.inputFinished() } catch (_: Exception) {}
                }

                val timeoutJob = launch {
                    delay((MAX_RECORD_SECONDS * 1000).toLong())
                    if (isRecording) {
                        audioRecorder.stopRecording()
                    }
                }

                audioRecorder.startRecording().collect { samples ->
                    // While the wake greeting is playing, drop mic audio so its
                    // echo doesn't reach the ASR or trip the VAD.
                    if (SystemClock.elapsedRealtime() < suppressRecordUntil) {
                        return@collect
                    }

                    if (warmupBuffers > 0) {
                        warmupBuffers--
                        return@collect
                    }

                    asrEngine.acceptWaveform(samples)

                    var sumSq = 0f
                    for (s in samples) sumSq += s * s
                    val rms = kotlin.math.sqrt(sumSq / samples.size)

                    if (rms < effectiveThreshold) {
                        silentChunks++
                        if (silentChunks >= VAD_MAX_SILENT_CHUNKS) {
                            timeoutJob.cancel()
                            audioRecorder.stopRecording()
                            return@collect
                        }
                    } else {
                        silentChunks = maxOf(0, silentChunks - 1)
                        speechChunkCount++
                    }
                }
                timeoutJob.cancel()
            } finally {
                if (isRecording && recordingGeneration == myGeneration) {
                    isRecording = false
                    lastSpeechChunkCount = speechChunkCount
                    val text = try { asrEngine.inputFinished() } catch (_: Exception) { null }
                    val cb = onSpeechEnd
                    onSpeechEnd = null
                    withContext(Dispatchers.Main) { cb?.invoke(text) }
                }
            }
        }
    }

    private fun stopRecording(onResult: (String?) -> Unit) {
        val myGeneration = ++recordingGeneration
        isRecording = false
        onSpeechEnd = null
        val job = recordingJob
        recordingJob = null
        audioRecorder.stopRecording()
        // Let the cancelled collect loop fully release the AudioRecord, then
        // finalize ASR ourselves — this is the tap-to-submit path and must
        // return the actual recognized text instead of throwing it away.
        activityScope.launch(Dispatchers.IO) {
            try { job?.join() } catch (_: Exception) {}
            // A new recording session started meanwhile — leave its ASR state alone.
            if (recordingGeneration != myGeneration) return@launch
            val text = try { asrEngine.inputFinished() } catch (_: Exception) { null }
            if (recordingGeneration != myGeneration) return@launch
            withContext(Dispatchers.Main) { onResult(text) }
        }
    }

    // ── TTS playback (sentence-by-sentence streaming) ─────────────────

    private fun speak(text: String, onDone: (() -> Unit)? = null) {
        if (!ttsReady) return
        val sentences = TextNormalizer.splitSentences(text)
        currentSpeakJob = activityScope.launch(Dispatchers.IO) {
            val sr = ttsEngine.getSampleRate()
            for (sentence in sentences) {
                val normalized = TextNormalizer.normalize(sentence)
                if (normalized.isBlank()) continue
                val audio = ttsEngine.synthesize(normalized)
                if (audio != null) {
                    val audioDurationMs = (audio.size.toLong() * 1000 / sr).toInt()
                    val timeline = VisemeGenerator.generateVisemeTimeline(normalized, audioDurationMs)
                    if (timeline != null) {
                        vrmController.sendVisemeTimeline(timeline)
                    }
                    audioPlayer.play(audio, sr)
                }
            }
            onDone?.let { withContext(Dispatchers.Main) { it() } }
        }
    }

    // ── Permission helpers ────────────────────────────────────────────

    private fun checkAudioPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
}

/** One synthesized sentence of a reply, paired with its display text. */
private class SpeechChunk(val pcm: FloatArray, val text: String)