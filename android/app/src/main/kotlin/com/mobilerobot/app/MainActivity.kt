package com.mobilerobot.app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.*
import androidx.core.content.ContextCompat
import com.mobilerobot.app.camera.FaceDetector
import com.mobilerobot.app.robot.BehaviorEngine
import com.mobilerobot.app.robot.Emotion
import com.mobilerobot.app.robot.RobotMode
import com.mobilerobot.app.robot.RobotState
import com.mobilerobot.app.ui.RobotFaceScreen
import com.rd.siri.asr.SherpaAsrEngine
import com.rd.siri.audio.AudioPlayer
import com.rd.siri.audio.AudioRecorder
import com.rd.siri.tts.SherpaTtsEngine
import kotlinx.coroutines.*
import kotlin.random.Random

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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        faceDetector = FaceDetector(this)

        // Init ASR/TTS in background (models must be downloaded first)
        Thread {
            asrReady = asrEngine.initialize()
            ttsReady = ttsEngine.initialize()
        }.start()

        setContent {
            var robotState by remember { mutableStateOf(RobotState()) }
            var hasCameraPermission by remember { mutableStateOf(checkCameraPermission()) }
            var hasAudioPermission by remember { mutableStateOf(checkAudioPermission()) }

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
                    val now = System.currentTimeMillis()
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
                    // Face appeared → WATCHING + greet
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

                    // Face lost too long → IDLE
                    !hasFace && idleTooLong && robotState.mode != RobotMode.IDLE
                        && robotState.mode != RobotMode.LISTENING
                        && robotState.mode != RobotMode.SPEAKING -> {
                        val remark = behaviorEngine.onFaceDisappear()
                        robotState = robotState.copy(mode = RobotMode.IDLE)
                        if (remark != null) speak(remark)
                    }
                }
            }

            // ── UI ──
            RobotFaceScreen(
                state = robotState,
                onTap = {
                    if (!hasAudioPermission) {
                        audioPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                        return@RobotFaceScreen
                    }
                    if (isRecording) {
                        // Stop recording and process
                        stopRecording { text ->
                            if (text != null && text.isNotBlank()) {
                                val (response, emotion) = behaviorEngine.respond(text)
                                robotState = robotState.copy(
                                    mode = RobotMode.SPEAKING,
                                    lastUserText = text,
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
                            } else {
                                robotState = robotState.copy(
                                    mode = if (robotState.faceTargetX != null)
                                        RobotMode.WATCHING else RobotMode.IDLE
                                )
                            }
                        }
                    } else {
                        // Start recording
                        startRecording()
                        robotState = robotState.copy(mode = RobotMode.LISTENING)
                    }
                }
            )
        }
    }

    // ── ASR recording ─────────────────────────────────────────────────

    private fun startRecording() {
        if (!asrReady) return
        isRecording = true
        recordingJob = CoroutineScope(Dispatchers.IO).launch {
            audioRecorder.startRecording().collect { samples ->
                asrEngine.acceptWaveform(samples)
            }
        }
    }

    private fun stopRecording(onResult: (String?) -> Unit) {
        isRecording = false
        recordingJob?.cancel()
        audioRecorder.stopRecording()
        Thread {
            val text = asrEngine.inputFinished()
            runOnUiThread { onResult(text) }
        }.start()
    }

    // ── TTS playback ──────────────────────────────────────────────────

    private fun speak(text: String, onDone: (() -> Unit)? = null) {
        if (!ttsReady) return
        Thread {
            val audio = ttsEngine.synthesize(text)
            if (audio != null) {
                runOnUiThread {
                    CoroutineScope(Dispatchers.IO).launch {
                        audioPlayer.play(audio, ttsEngine.sampleRate)
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
