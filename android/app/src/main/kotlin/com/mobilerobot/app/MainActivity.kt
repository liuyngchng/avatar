package com.mobilerobot.app

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
import com.mobilerobot.app.camera.FaceDetector
import com.mobilerobot.app.robot.BehaviorEngine
import com.mobilerobot.app.robot.Emotion
import com.mobilerobot.app.robot.RobotMode
import com.mobilerobot.app.robot.RobotState
import com.mobilerobot.app.ui.RobotFaceScreen
import android.util.Log
import com.rd.siri.asr.SherpaAsrEngine
import com.rd.siri.audio.AudioPlayer
import com.rd.siri.audio.AudioRecorder
import com.rd.siri.audio.VoiceService
import com.rd.siri.audio.WakeWordManager
import com.rd.siri.chat.ChatSession
import com.rd.siri.chat.LlmClient
import com.rd.siri.config.ConfigRepository
import com.rd.siri.config.ConfigViewModel
import com.rd.siri.model.ModelManager
import com.rd.siri.tts.SherpaTtsEngine
import com.rd.siri.ui.ModelSetupScreen
import com.rd.siri.ui.SettingsHubScreen
import com.rd.siri.ui.SettingsScreen
import kotlinx.coroutines.*
import kotlin.random.Random

/** Navigation destinations for the settings stack. */
private sealed class Screen {
    object RobotFace : Screen()
    object SettingsHub : Screen()
    object LlmConfig : Screen()
    object ModelSetup : Screen()
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

            // Collect face detection results
            LaunchedEffect(Unit) {
                faceDetector.faces.collect { result ->
                    robotState = robotState.copy(
                        faceTargetX = result?.cx,
                        faceTargetY = result?.cy,
                        msSinceLastFace = if (result != null) 0L
                            else robotState.msSinceLastFace + 200
                    )
                }
            }

            // Blink timer
            LaunchedEffect(Unit) {
                while (true) {
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
                                }
                            }

                            if (isRecording) {
                                stopRecording { onSpeechResult(it) }
                            } else {
                                startRecording { onSpeechResult(it) }
                                robotState = robotState.copy(mode = RobotMode.LISTENING)
                            }
                        },
                        onLongPress = {
                            currentScreen = Screen.SettingsHub
                        }
                    )
                }

                is Screen.SettingsHub -> {
                    SettingsHubScreen(
                        onNavigateToLlmConfig = { currentScreen = Screen.LlmConfig },
                        onNavigateToModelSetup = { currentScreen = Screen.ModelSetup },
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

        recordingJob = CoroutineScope(Dispatchers.IO).launch {
            try {
                audioRecorder.startRecording().collect { samples ->
                    asrEngine.acceptWaveform(samples)

                    // VAD: RMS energy-based silence detection
                    var sumSq = 0f
                    for (s in samples) sumSq += s * s
                    val rms = kotlin.math.sqrt(sumSq / samples.size)

                    if (rms < VAD_SILENCE_THRESHOLD) {
                        silentChunks++
                        if (silentChunks >= VAD_MAX_SILENT_CHUNKS) {
                            audioRecorder.stopRecording()
                            return@collect // flow completes → finally decodes
                        }
                    } else {
                        silentChunks = maxOf(0, silentChunks - 1)
                    }
                }
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
        Thread {
            val audio = ttsEngine.synthesize(text)
            if (audio != null) {
                runOnUiThread {
                    CoroutineScope(Dispatchers.IO).launch {
                        audioPlayer.play(audio, ttsEngine.getSampleRate())
                        onDone?.let { runOnUiThread { it() } }
                    }
                }
            } else {
                onDone?.let { runOnUiThread { it() } }
            }
        }.start()
    }

    // ── Permission helpers ────────────────────────────────────────────

    private fun checkCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    private fun checkAudioPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
}
