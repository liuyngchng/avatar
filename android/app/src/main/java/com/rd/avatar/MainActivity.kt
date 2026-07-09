package com.rd.avatar

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.PowerManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.*
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import com.rd.avatar.camera.FaceDetector
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

    private lateinit var faceDetector: FaceDetector
    private val behaviorEngine = BehaviorEngine()

    // Sherpa-onnx engines (offline)
    private val asrEngine by lazy { SherpaAsrEngine(this) }
    private val ttsEngine by lazy { SherpaTtsEngine(this) }
    private val audioPlayer = AudioPlayer()
    private val audioRecorder = AudioRecorder(this)

    private var asrReady = false
    private var ttsReady = false
    private var isRecording = false
    private var recordingJob: Job? = null
    private var onSpeechEnd: ((String?) -> Unit)? = null

    // VAD (Voice Activity Detection) constants
    companion object {
        private const val VAD_SILENCE_THRESHOLD = 0.012f  // RMS below this = silence
        private const val VAD_MAX_SILENT_CHUNKS = 25       // ~2 seconds at 80ms/chunk
        private const val MAX_RECORD_SECONDS = 10f         // force-stop if no silence
    }

    // LLM integration
    private val configRepository by lazy { ConfigRepository(this) }
    private val llmClient by lazy { LlmClient(configRepository) }
    private val chatSession by lazy { ChatSession(llmClient) }
    private var llmConfigured = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        llmConfigured = configRepository.hasConfig
        Log.i("MainActivity", "LLM configured: $llmConfigured")

        faceDetector = FaceDetector(this)

        setContent {
            var robotState by remember { mutableStateOf(RobotState()) }
            var hasCameraPermission by remember { mutableStateOf(checkCameraPermission()) }
            var hasAudioPermission by remember { mutableStateOf(checkAudioPermission()) }

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

            // Initialize ASR/TTS when models become ready
            LaunchedEffect(modelsReady) {
                if (modelsReady && !asrReady) {
                    withContext(Dispatchers.IO) {
                        asrReady = asrEngine.initialize()
                        ttsReady = ttsEngine.initialize()
                    }
                }
            }

            // Permission launchers
            val cameraPermissionLauncher = rememberLauncherForActivityResult(
                ActivityResultContracts.RequestPermission()
            ) { granted -> hasCameraPermission = granted }

            val audioPermissionLauncher = rememberLauncherForActivityResult(
                ActivityResultContracts.RequestPermission()
            ) { granted -> hasAudioPermission = granted }

            // Start camera when permission granted
            LaunchedEffect(hasCameraPermission) {
                if (hasCameraPermission) {
                    faceDetector.start(this@MainActivity)
                }
            }

            // Collect face detection results (conflated to reduce recomposition pressure)
            LaunchedEffect(Unit) {
                faceDetector.faces.collect { result ->
                    // Skip redundant updates: only update state if face presence changed
                    // or coordinates shifted meaningfully (>1% of screen)
                    val prevHasFace = robotState.faceTargetX != null
                    val hasFace = result != null
                    if (!prevHasFace && !hasFace) {
                        robotState = robotState.copy(
                            msSinceLastFace = robotState.msSinceLastFace + 200
                        )
                        return@collect
                    }
                    robotState = robotState.copy(
                        faceTargetX = result?.cx,
                        faceTargetY = result?.cy,
                        msSinceLastFace = if (hasFace) 0L
                            else robotState.msSinceLastFace + 200
                    )
                }
            }

            // Blink timer
            LaunchedEffect(Unit) {
                while (isActive) {
                    delay(Random.nextLong(2000, 5000))
                    robotState = robotState.copy(
                        blinkTrigger = robotState.blinkTrigger + 1
                    )
                }
            }

            // Request permissions on first launch
            LaunchedEffect(Unit) {
                if (!hasCameraPermission) {
                    cameraPermissionLauncher.launch(Manifest.permission.CAMERA)
                }
                if (!hasAudioPermission) {
                    audioPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                }
            }

            // Mode transitions based on face presence
            LaunchedEffect(robotState.faceTargetX, robotState.mode) {
                val hasFace = robotState.faceTargetX != null
                val idleTooLong = robotState.msSinceLastFace > 10_000L

                when {
                    hasFace && robotState.mode == RobotMode.IDLE -> {
                        val greeting = behaviorEngine.onFaceAppear()
                        robotState = robotState.copy(
                            mode = RobotMode.WATCHING,
                            responseText = greeting,
                            emotion = Emotion.HAPPY
                        )
                        delay(800)
                        speak(greeting)
                    }

                    !hasFace && idleTooLong && robotState.mode != RobotMode.IDLE
                        && robotState.mode != RobotMode.LISTENING
                        && robotState.mode != RobotMode.SPEAKING -> {
                        val remark = behaviorEngine.onFaceDisappear()
                        robotState = robotState.copy(mode = RobotMode.IDLE)
                        if (remark != null) speak(remark)
                    }
                }
            }

            // ── Screen routing ──
            when (currentScreen) {
                is Screen.RobotFace -> {
                    RobotFaceScreen(
                        state = robotState,
                        onTap = {
                            if (!hasAudioPermission) {
                                audioPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                                return@RobotFaceScreen
                            }
                            // Guard: ASR must be ready before entering LISTENING mode.
                            // Without this check, the mode would be set to LISTENING
                            // but recording never starts, leaving the UI stuck forever.
                            if (!asrReady) {
                                return@RobotFaceScreen
                            }
                            // If wake word detection is running, stop it to release
                            // the microphone before starting recording. Same pattern
                            // as the wake-word-triggered flow (VoiceService.stopEngine).
                            if (wakeWordEnabled) {
                                stopWakeWordService()
                            }
                            // Shared result handler (VAD auto-stop or manual tap-to-stop)
                            val onSpeechResult: (String?) -> Unit = { text ->
                                if (text != null && text.isNotBlank()) {
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
                                            robotState = robotState.copy(
                                                mode = if (robotState.faceTargetX != null)
                                                    RobotMode.WATCHING else RobotMode.IDLE,
                                                isSpeaking = false
                                            )
                                        }
                                    }
                                } else {
                                    robotState = robotState.copy(
                                        mode = if (robotState.faceTargetX != null)
                                            RobotMode.WATCHING else RobotMode.IDLE
                                    )
                                    speak("没听清，请再说一遍")
                                }
                            }

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
                            // Speak the text using TTS
                            robotState = robotState.copy(
                                mode = RobotMode.SPEAKING,
                                responseText = text,
                                isSpeaking = true
                            )
                            speak(text) {
                                robotState = robotState.copy(
                                    mode = if (robotState.faceTargetX != null)
                                        RobotMode.WATCHING else RobotMode.IDLE,
                                    isSpeaking = false
                                )
                            }
                        }
                    )
                }
            }
        }
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
        startService(intent)
    }

    // ── ASR recording ─────────────────────────────────────────────────

    private fun startRecording(onResult: (String?) -> Unit) {
        if (!asrReady) return
        isRecording = true
        onSpeechEnd = onResult
        var silentChunks = 0
        val startTime = System.currentTimeMillis()

        recordingJob = CoroutineScope(Dispatchers.IO).launch {
            try {
                // Max duration timeout: force-stop after MAX_RECORD_SECONDS
                val timeoutJob = launch {
                    delay((MAX_RECORD_SECONDS * 1000).toLong())
                    if (isRecording) {
                        audioRecorder.stopRecording()
                    }
                }

                audioRecorder.startRecording().collect { samples ->
                    asrEngine.acceptWaveform(samples)

                    // VAD: RMS energy-based silence detection
                    var sumSq = 0f
                    for (s in samples) sumSq += s * s
                    val rms = kotlin.math.sqrt(sumSq / samples.size)

                    if (rms < VAD_SILENCE_THRESHOLD) {
                        silentChunks++
                        if (silentChunks >= VAD_MAX_SILENT_CHUNKS) {
                            timeoutJob.cancel()
                            audioRecorder.stopRecording()
                            return@collect // flow completes → finally decodes
                        }
                    } else {
                        silentChunks = maxOf(0, silentChunks - 1)
                    }
                }
                timeoutJob.cancel()
            } finally {
                // Decode ASR result after recording stops (VAD or manual)
                if (isRecording) {
                    isRecording = false
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
        audioRecorder.stopRecording()
    }

    // ── TTS playback ──────────────────────────────────────────────────

    private fun speak(text: String, onDone: (() -> Unit)? = null) {
        if (!ttsReady) return
        val normalized = TextNormalizer.normalize(text)
        CoroutineScope(Dispatchers.IO).launch {
            val audio = ttsEngine.synthesize(normalized)
            if (audio != null) {
                audioPlayer.play(audio, ttsEngine.getSampleRate())
                onDone?.let { withContext(Dispatchers.Main) { it() } }
            } else {
                onDone?.let { withContext(Dispatchers.Main) { it() } }
            }
        }
    }

    // ── Permission helpers ────────────────────────────────────────────

    private fun checkCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    private fun checkAudioPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
}
