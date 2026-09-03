package com.rd.avatar

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
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

    // Lifecycle-aware scope
    private val activityScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    // VAD constants
    companion object {
        private const val VAD_SILENCE_THRESHOLD = 0.022f
        private const val VAD_MAX_SILENT_CHUNKS = 20
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
            val wakeWordEnabled by WakeWordManager.isRunning.collectAsState()

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
                    stopRecording { } // stop any in-progress recording
                    WakeWordManager.notifyVoiceFlowDone()
                    audioPlayer.stop()
                    robotState = robotState.copy(mode = RobotMode.IDLE, isSpeaking = false)
                }
            }

            /** End the conversation and return to idle. */
            fun endConversation() {
                conversationActive = false
                conversationTimeoutJob?.cancel()
                conversationTimeoutJob = null
                WakeWordManager.notifyVoiceFlowDone()
                robotState = robotState.copy(mode = RobotMode.IDLE, isSpeaking = false)
            }

            // ─── Speech result handler ─────────────────────────────────
            var onSpeechResult: ((String?) -> Unit)? = null
            onSpeechResult = onResult@ { text ->
                // Minimum-speech gate: filter out echo/reverb.
                val minSpeechChunks = 6  // ~500ms at ~80ms/buffer
                if (lastSpeechChunkCount < minSpeechChunks) {
                    Log.i("MainActivity",
                        "Utterance too short (${lastSpeechChunkCount} chunks < $minSpeechChunks), treating as echo")
                    if (conversationActive) {
                        // Still in conversation — go back to listening.
                        robotState = robotState.copy(mode = RobotMode.LISTENING, isSpeaking = false)
                        startRecording(onSpeechResult!!)
                    }
                    return@onResult
                }

                if (text != null && text.isNotBlank()) {
                    resetConversationTimeout()
                    robotState = robotState.copy(
                        mode = RobotMode.THINKING,
                        lastUserText = text,
                        emotion = Emotion.CURIOUS,
                        isSpeaking = false
                    )
                    scope.launch {
                        val (response, emotion) = if (configRepository.hasConfig) {
                            chatSession.send(text).fold(
                                onSuccess = { it to Emotion.HAPPY },
                                onFailure = { e ->
                                    Log.w("MainActivity", "LLM fail, fallback to rules", e)
                                    behaviorEngine.respond(text)
                                }
                            )
                        } else {
                            behaviorEngine.respond(text)
                        }
                        robotState = robotState.copy(
                            mode = RobotMode.SPEAKING,
                            responseText = response,
                            emotion = emotion,
                            isSpeaking = true
                        )
                        speak(response) {
                            if (conversationActive) {
                                // Post-speech cooldown, then auto-listen.
                                scope.launch {
                                    delay(800)
                                    robotState = robotState.copy(mode = RobotMode.LISTENING, isSpeaking = false)
                                    startRecording(onSpeechResult!!)
                                }
                            } else {
                                robotState = robotState.copy(mode = RobotMode.IDLE, isSpeaking = false)
                            }
                        }
                    }
                } else {
                    // Blank / empty speech
                    if (conversationActive) {
                        // Go back to listening — timeout will fire if user stays silent.
                        robotState = robotState.copy(mode = RobotMode.LISTENING, isSpeaking = false)
                        startRecording(onSpeechResult!!)
                    } else {
                        robotState = robotState.copy(mode = RobotMode.IDLE)
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
                    loadingStatus = "正在加载 ASR 语音识别模型..."
                    withContext(Dispatchers.IO) {
                        asrReady = asrEngine.initialize()
                    }
                    if (asrReady) {
                        loadingStatus = "正在加载 TTS 语音合成模型..."
                        withContext(Dispatchers.IO) {
                            ttsReady = ttsEngine.initialize()
                        }
                    }
                    // Noise calibration runs in background.
                    calibrateNoiseOnce()
                    // ASR + TTS are ready. VRM loads in the WebView.
                    enginesReady = true
                    loadingStatus = "正在加载 VRM 数字人模型..."
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
                                robotState = robotState.copy(mode = RobotMode.IDLE, isSpeaking = false)
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
                    resetConversationTimeout()
                    stopWakeWordService()

                    // Greeting TTS
                    val greetingPcm = withContext(Dispatchers.IO) {
                        ttsEngine.synthesize("哎，我在呢")
                    }
                    if (greetingPcm != null) {
                        robotState = robotState.copy(mode = RobotMode.SPEAKING, isSpeaking = true)
                        val sr = ttsEngine.getSampleRate()
                        val greetingDurMs = (greetingPcm.size.toLong() * 1000 / sr).toInt()
                        val timeline = VisemeGenerator.generateVisemeTimeline("哎，我在呢", greetingDurMs)
                        if (timeline != null) {
                            vrmController.sendVisemeTimeline(timeline)
                        }
                        withContext(Dispatchers.IO) {
                            audioPlayer.play(greetingPcm, sr)
                        }
                    }
                    delay(800)  // post-speech cooldown
                    robotState = robotState.copy(mode = RobotMode.LISTENING, isSpeaking = false)
                    startRecording(onSpeechResult)
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
                                    // Stop TTS.
                                    audioPlayer.stop()
                                    if (conversationActive) {
                                        // Still in conversation — go to listening.
                                        scope.launch {
                                            delay(300)
                                            robotState = robotState.copy(mode = RobotMode.LISTENING, isSpeaking = false)
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
                                        stopWakeWordService()
                                    }
                                    conversationActive = true
                                    resetConversationTimeout()
                                    startRecording { onSpeechResult(it) }
                                    robotState = robotState.copy(mode = RobotMode.LISTENING)
                                }
                            }
                        },
                        onSettingsClick = {
                            currentScreen = Screen.SettingsHub
                        },
                        wakeWordEnabled = wakeWordEnabled,
                        onToggleWakeWord = {
                            if (wakeWordEnabled) {
                                stopWakeWordService()
                            } else {
                                startWakeWordService()
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
                                robotState = robotState.copy(mode = RobotMode.IDLE, isSpeaking = false)
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
        var warmupBuffers = 5
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
        recordingGeneration++
        isRecording = false
        onSpeechEnd = onResult
        recordingJob?.cancel()
        recordingJob = null
        audioRecorder.stopRecording()
        onSpeechEnd = null
        onResult(null)
    }

    // ── TTS playback (sentence-by-sentence streaming) ─────────────────

    private fun speak(text: String, onDone: (() -> Unit)? = null) {
        if (!ttsReady) return
        val sentences = TextNormalizer.splitSentences(text)
        activityScope.launch(Dispatchers.IO) {
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