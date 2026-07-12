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
import com.rd.avatar.ui.RobotFaceScreen
import android.util.Log
import com.rd.avatar.asr.SherpaAsrEngine
import com.rd.avatar.audio.AudioPlayer
import com.rd.avatar.audio.AudioRecorder
import com.rd.avatar.audio.VoiceService
import com.rd.avatar.audio.WakeWordManager
import com.rd.avatar.chat.ChatSession
import com.rd.avatar.chat.LlmClient
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
    @Volatile private var lastSpeechChunkCount = 0  // non-silent buffer count for min-speech gate

    // Lifecycle-aware scope — cancelled in onDestroy to prevent leaks
    private val activityScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    // VAD (Voice Activity Detection) constants
    companion object {
        // Base silence threshold (RMS). Actual threshold = max(this, noiseFloor * 1.8)
        private const val VAD_SILENCE_THRESHOLD = 0.022f
        // Consecutive silent chunks to auto-stop (~80ms/chunk)
        private const val VAD_MAX_SILENT_CHUNKS = 20
        // Chunks used to calibrate ambient noise floor (~1.6s)
        private const val NOISE_CALIBRATION_CHUNKS = 20
        // Max recording duration before force-stop
        private const val MAX_RECORD_SECONDS = 10f
    }

    // Calibrated once at startup, used for all subsequent VAD
    private var calibratedNoiseThreshold: Float = VAD_SILENCE_THRESHOLD

    // LLM integration
    private val configRepository by lazy { ConfigRepository(this) }
    private val llmClient by lazy { LlmClient(configRepository) }
    private val chatSession by lazy { ChatSession(llmClient) }
    private var llmConfigured = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Clear chat history and LLM context on app (re)start
        chatSession.clear()

        llmConfigured = configRepository.hasConfig
        Log.i("MainActivity", "LLM configured: $llmConfigured")

        setContent {
            var robotState by remember { mutableStateOf(RobotState()) }
            var hasAudioPermission by remember { mutableStateOf(checkAudioPermission()) }
            var enginesReady by remember { mutableStateOf(false) }

            // Settings navigation
            val modelsReady = ModelManager.checkAsrReady(this) &&
                ModelManager.checkTtsReady(this)
            var currentScreen by remember {
                mutableStateOf<Screen>(if (modelsReady) Screen.RobotFace else Screen.ModelSetup)
            }

            // Coroutine scope for LLM calls
            val scope = rememberCoroutineScope()

            // Wake word toggle state
            val wakeWordEnabled by WakeWordManager.isRunning.collectAsState()

            // Wake-word-triggered session tracking
            var wakeWordTriggered by remember { mutableStateOf(false) }
            var isMultiTurn by remember { mutableStateOf(false) }
            var multiTurnBlankCount by remember { mutableIntStateOf(0) }

            // Shared speech-result handler for both tap-to-talk and wake-word flows.
            // Defined here so both the onTap lambda and the wakeEvents collector can access it.
            // Must be a var (not val) because the lambda self-references inside speak() callbacks.
            var onSpeechResult: ((String?) -> Unit)? = null
            onSpeechResult = onResult@ { text ->
                // Minimum-speech gate: if the utterance is too short
                // (< ~500ms of actual speech energy), treat it as
                // echo/reverb rather than real user input.  This stops
                // the robot from responding to its own TTS tail in
                // multi-turn mode.
                val minSpeechChunks = 6  // ~500ms at ~80ms/buffer
                if (isMultiTurn && lastSpeechChunkCount < minSpeechChunks) {
                    Log.i("MainActivity",
                        "Utterance too short (${lastSpeechChunkCount} chunks < $minSpeechChunks), treating as echo")
                    multiTurnBlankCount++
                    if (multiTurnBlankCount >= 2) {
                        isMultiTurn = false
                        multiTurnBlankCount = 0
                        wakeWordTriggered = false
                        WakeWordManager.notifyVoiceFlowDone()
                        robotState = robotState.copy(mode = RobotMode.IDLE)
                    } else {
                        speak("嗯？还在吗？") {
                            scope.launch {
                                delay(800)  // post-speech cooldown
                                robotState = robotState.copy(
                                    mode = RobotMode.LISTENING, isSpeaking = false)
                                startRecording(onSpeechResult!!)
                            }
                        }
                    }
                    return@onResult
                }

                if (text != null && text.isNotBlank()) {
                    // Productive wake: reset debounce
                    if (wakeWordTriggered) {
                        WakeWordManager.notifyProductiveWake()
                    }
                    multiTurnBlankCount = 0
                    robotState = robotState.copy(
                        mode = RobotMode.THINKING,
                        lastUserText = text,
                        emotion = Emotion.CURIOUS,
                        isSpeaking = false
                    )
                    scope.launch {
                        // Check if user is asking to look at something
                        val wantsCamera = text.contains("看") &&
                            (text.contains("外面") || text.contains("什么") ||
                             text.contains("哪里") || text.contains("前面"))

                        if (wantsCamera) {
                            robotState = robotState.copy(
                                mode = RobotMode.LOOKING,
                                emotion = Emotion.CURIOUS
                            )
                            delay(1500)
                        }

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
                            if (isMultiTurn) {
                                // Post-speech cooldown: wait for room acoustics
                                // to settle before opening the mic, so we don't
                                // capture our own TTS tail as the next utterance.
                                scope.launch {
                                    delay(800)  // 800ms post-speech cooldown
                                    robotState = robotState.copy(
                                        mode = RobotMode.LISTENING,
                                        isSpeaking = false
                                    )
                                    startRecording(onSpeechResult!!)
                                }
                            } else {
                                robotState = robotState.copy(
                                    mode = RobotMode.IDLE,
                                    isSpeaking = false
                                )
                            }
                            if (wakeWordTriggered) {
                                wakeWordTriggered = false
                                WakeWordManager.notifyVoiceFlowDone()
                            }
                        }
                    }
                } else {
                    // Blank / empty speech
                    if (isMultiTurn) {
                        multiTurnBlankCount++
                        if (multiTurnBlankCount >= 2) {
                            // End multi-turn after two consecutive blanks
                            isMultiTurn = false
                            multiTurnBlankCount = 0
                            wakeWordTriggered = false
                            WakeWordManager.notifyVoiceFlowDone()
                            robotState = robotState.copy(mode = RobotMode.IDLE)
                        } else {
                            // Prompt user to continue
                            speak("嗯？还在吗？") {
                                scope.launch {
                                    delay(800)  // post-speech cooldown
                                    robotState = robotState.copy(
                                        mode = RobotMode.LISTENING,
                                        isSpeaking = false
                                    )
                                    startRecording(onSpeechResult!!)
                                }
                            }
                        }
                    } else {
                        robotState = robotState.copy(mode = RobotMode.IDLE)
                        if (wakeWordTriggered) {
                            WakeWordManager.notifyFalseTrigger()
                            wakeWordTriggered = false
                            WakeWordManager.notifyVoiceFlowDone()
                        }
                        speak("没听清，请再说一遍")
                    }
                }
            }

            // Initialize ASR/TTS when models become ready
            LaunchedEffect(modelsReady) {
                if (modelsReady && !asrReady) {
                    // Show waking-up state during engine loading
                    robotState = robotState.copy(
                        mode = RobotMode.THINKING,
                        emotion = Emotion.SLEEPY
                    )
                    withContext(Dispatchers.IO) {
                        asrReady = asrEngine.initialize()
                        ttsReady = ttsEngine.initialize()
                    }
                    enginesReady = true
                    robotState = robotState.copy(
                        mode = RobotMode.IDLE,
                        emotion = Emotion.NEUTRAL
                    )
                    // One-time ambient noise calibration for VAD
                    calibrateNoiseOnce()
                } else if (asrReady && ttsReady) {
                    // Already initialized (fast phone, or modelsReady was cached)
                    enginesReady = true
                }
            }

            // Audio permission launcher
            val audioPermissionLauncher = rememberLauncherForActivityResult(
                ActivityResultContracts.RequestPermission()
            ) { granted -> hasAudioPermission = granted }

            // ── Blink timer ──
            LaunchedEffect(Unit) {
                while (isActive) {
                    delay(Random.nextLong(2000, 5000))
                    robotState = robotState.copy(
                        blinkTrigger = robotState.blinkTrigger + 1
                    )
                }
            }

            // ── Random antic timer (goofy idle animations) ──
            LaunchedEffect(Unit) {
                while (isActive) {
                    delay(Random.nextLong(6000, 15000))
                    if (robotState.mode == RobotMode.IDLE) {
                        robotState = robotState.copy(
                            anticTrigger = robotState.anticTrigger + 1,
                            emotion = Emotion.GOOFY
                        )
                        // Revert emotion after a moment
                        delay(3000)
                        if (robotState.mode == RobotMode.IDLE &&
                            robotState.emotion == Emotion.GOOFY) {
                            robotState = robotState.copy(emotion = Emotion.NEUTRAL)
                        }
                    }
                }
            }

            // ── Random goofy remarks during idle ──
            LaunchedEffect(robotState.mode) {
                if (robotState.mode == RobotMode.IDLE) {
                    delay(Random.nextLong(15000, 30000))
                    if (robotState.mode == RobotMode.IDLE &&
                        robotState.anticTrigger > 0 &&
                        robotState.anticTrigger % 3 == 0L) {
                        val remark = behaviorEngine.randomAntic()
                        if (remark != null) {
                            robotState = robotState.copy(
                                mode = RobotMode.SPEAKING,
                                responseText = remark,
                                isSpeaking = true
                            )
                            speak(remark) {
                                robotState = robotState.copy(
                                    mode = RobotMode.IDLE,
                                    isSpeaking = false
                                )
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

            // ── Wake word event → start voice flow (the missing link) ──
            LaunchedEffect(Unit) {
                WakeWordManager.wakeEvents.collect {
                    if (!enginesReady) return@collect
                    if (robotState.mode != RobotMode.IDLE && robotState.mode != RobotMode.LOOKING) {
                        Log.i("MainActivity", "Ignoring wake word — not idle/looking")
                        return@collect
                    }
                    Log.i("MainActivity", "Wake word triggered — starting voice flow")
                    wakeWordTriggered = true
                    isMultiTurn = true
                    multiTurnBlankCount = 0

                    // Play greeting TTS, then auto-listen
                    val greetingPcm = withContext(Dispatchers.IO) {
                        ttsEngine.synthesize("哎，我在呢")
                    }
                    if (greetingPcm != null) {
                        robotState = robotState.copy(mode = RobotMode.SPEAKING, isSpeaking = true)
                        withContext(Dispatchers.IO) {
                            audioPlayer.play(greetingPcm, ttsEngine.getSampleRate())
                        }
                    }
                    // Post-speech cooldown: let room acoustics settle
                    // before opening the mic for the user's first utterance.
                    robotState = robotState.copy(mode = RobotMode.LISTENING, isSpeaking = false)
                    delay(800)  // 800ms cooldown
                    startRecording(onSpeechResult)
                }
            }

            // ── Screen routing ──
            when (currentScreen) {
                is Screen.RobotFace -> {
                    RobotFaceScreen(
                        state = robotState,
                        enginesReady = enginesReady,
                        onTap = {
                            if (!hasAudioPermission) {
                                audioPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                                return@RobotFaceScreen
                            }
                            if (!enginesReady) {
                                return@RobotFaceScreen
                            }
                            if (wakeWordEnabled) {
                                stopWakeWordService()
                            }

                            // Tap-to-talk: not a wake-word session
                            wakeWordTriggered = false
                            isMultiTurn = false

                            if (isRecording) {
                                stopRecording { onSpeechResult(it) }
                            } else {
                                startRecording { onSpeechResult(it) }
                                robotState = robotState.copy(mode = RobotMode.LISTENING)
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
                        }
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
                            if (enabled) {
                                startWakeWordService()
                            } else {
                                stopWakeWordService()
                            }
                        }
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
                        onBack = {
                            currentScreen = Screen.SettingsHub
                        }
                    )
                }

                is Screen.TextReader -> {
                    TextReaderScreen(
                        onBack = { currentScreen = Screen.SettingsHub },
                        onRead = { text ->
                            robotState = robotState.copy(
                                mode = RobotMode.SPEAKING,
                                responseText = text,
                                isSpeaking = true
                            )
                            speak(text) {
                                robotState = robotState.copy(
                                    mode = RobotMode.IDLE,
                                    isSpeaking = false
                                )
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

    /** Calibrate noise threshold once at startup. */
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
                // Safety timeout: stop calibration after 3s
                delay(3000)
                job.cancel()
            } catch (_: Exception) {
                Log.w("MainActivity", "Noise calibration failed, using default threshold")
            }
        }
    }

    private fun startRecording(onResult: (String?) -> Unit) {
        if (!asrReady) return
        isRecording = true
        onSpeechEnd = onResult
        var silentChunks = 0
        var warmupBuffers = 5  // skip first ~5 buffers (~400ms) to avoid TTS tail/echo
        var speechChunkCount = 0  // non-silent buffers for minimum-speech gate
        val effectiveThreshold = calibratedNoiseThreshold

        // Cancel any stale job before starting a new one
        recordingJob?.cancel()
        recordingJob = activityScope.launch(Dispatchers.IO) {
            try {
                val timeoutJob = launch {
                    delay((MAX_RECORD_SECONDS * 1000).toLong())
                    if (isRecording) {
                        audioRecorder.stopRecording()
                    }
                }

                audioRecorder.startRecording().collect { samples ->
                    // Warm-up: drop the first few buffers so residual TTS echo
                    // doesn't trigger a false VAD start.
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
                if (isRecording) {
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
        onSpeechEnd = onResult
        recordingJob?.cancel()
        recordingJob = null
        audioRecorder.stopRecording()
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
