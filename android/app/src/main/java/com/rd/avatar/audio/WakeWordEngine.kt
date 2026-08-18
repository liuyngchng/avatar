package com.rd.avatar.audio

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Process
import android.util.Log
import androidx.core.content.ContextCompat
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.sqrt

class WakeWordEngine(private val context: Context) {

    companion object {
        private const val TAG = "RobotCompanion"
        const val SAMPLE_RATE = 16000
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT

        // Reduced from 4 to 2: 2 × minBufSize (~640 samples at 16kHz) ≈ 1280 samples = 80ms.
        // Keeps detection latency low without risking buffer underruns.
        private const val BUFFER_SIZE_FACTOR = 2

        // RMS energy below this threshold is treated as silence.
        // 0.0008 = ~-62 dBFS — very conservative, catches fricative consonants
        // (e.g. "x" in "小") while filtering true silence / idle noise.
        private const val ENERGY_THRESHOLD = 0.0008f

        // Once speech energy is detected, keep feeding audio for this many
        // additional buffers even if energy drops. Covers low-energy phonemes
        // within a word (fricatives, stops). 6 × ~80ms buffer ≈ 480ms hangover.
        private const val ENERGY_HANGOVER_BUFFERS = 6
    }

    @Volatile
    private var spotterPtr: Long = 0
    @Volatile
    private var keywordsContent: String = ""

    private val isRunning = AtomicBoolean(false)
    @Volatile
    private var detectionThread: Thread? = null
    @Volatile
    private var audioRecord: AudioRecord? = null

    val isReady: Boolean get() = spotterPtr != 0L

    fun initialize(modelDir: File, numThreads: Int = 1): Boolean {
        if (spotterPtr != 0L) {
            Log.w(TAG, "WakeWordEngine: already initialized")
            return true
        }

        keywordsContent = try {
            context.assets.open("kws_keywords.txt").bufferedReader().use { it.readText().trim() }
        } catch (e: Exception) {
            Log.e(TAG, "WakeWordEngine: failed to read keywords from assets", e)
            return false
        }
        Log.i(TAG, "WakeWordEngine: keywords='${keywordsContent}'")

        Log.i(TAG, "WakeWordEngine: initializing with modelDir=${modelDir.absolutePath}, threads=$numThreads")
        spotterPtr = nativeCreateSpotter(modelDir.absolutePath, keywordsContent, numThreads)
        if (spotterPtr == 0L) {
            Log.e(TAG, "WakeWordEngine: failed to create spotter")
            return false
        }
        Log.i(TAG, "WakeWordEngine: initialized successfully")
        return true
    }

    /**
     * Start continuous wake word detection on a background thread.
     * [onDetected] is called when a wake word is detected.
     * [onError] is called when the detection loop exits abnormally (e.g. JNI crash),
     * so the caller can attempt recovery.
     */
    fun start(
        onDetected: (keyword: String) -> Unit,
        onError: ((message: String) -> Unit)? = null
    ) {
        if (spotterPtr == 0L) {
            Log.e(TAG, "WakeWordEngine: not initialized")
            return
        }
        if (isRunning.getAndSet(true)) {
            Log.w(TAG, "WakeWordEngine: already running")
            return
        }

        detectionThread = Thread({
            android.os.Process.setThreadPriority(Process.THREAD_PRIORITY_DEFAULT)
            runDetectionLoop(onDetected, onError)
        }).apply {
            name = "WakeWordDetection"
            start()
        }
    }

    fun stop() {
        isRunning.set(false)
        audioRecord?.stop()
        // Don't join the detection thread if called from within it
        val thread = detectionThread
        if (thread != null && thread.id != Thread.currentThread().id) {
            thread.join(1000)
        }
        detectionThread = null
    }

    fun destroy() {
        stop()
        if (spotterPtr != 0L) {
            nativeDestroySpotter(spotterPtr)
            spotterPtr = 0
            Log.i(TAG, "WakeWordEngine: destroyed")
        }
    }

    // ── Detection loop ───────────────────────────────────────────────────────

    @SuppressLint("MissingPermission")
    private fun runDetectionLoop(
        onDetected: (String) -> Unit,
        onError: ((String) -> Unit)?
    ) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            Log.e(TAG, "WakeWordEngine: RECORD_AUDIO permission not granted")
            isRunning.set(false)
            onError?.invoke("RECORD_AUDIO permission not granted")
            return
        }

        val streamPtr = nativeCreateStream(spotterPtr)
        if (streamPtr == 0L) {
            Log.e(TAG, "WakeWordEngine: failed to create keyword stream")
            isRunning.set(false)
            onError?.invoke("Failed to create keyword stream")
            return
        }

        val bufferSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
            .let { it * BUFFER_SIZE_FACTOR }

        val recorder = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            SAMPLE_RATE,
            CHANNEL_CONFIG,
            AUDIO_FORMAT,
            bufferSize
        )

        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            nativeDestroyStream(streamPtr)
            isRunning.set(false)
            onError?.invoke("AudioRecord init failed")
            Log.e(TAG, "WakeWordEngine: AudioRecord init failed")
            return
        }

        audioRecord = recorder

        try {
            recorder.startRecording()
            Log.i(TAG, "WakeWordEngine: detection loop started")

            val shortBuf = ShortArray(bufferSize / 2)
            val floatBuf = FloatArray(bufferSize / 2)
            var hangover = 0

            while (isRunning.get()) {
                val n = recorder.read(shortBuf, 0, shortBuf.size)
                if (n <= 0) break

                for (i in 0 until n) {
                    floatBuf[i] = shortBuf[i].toFloat() / Short.MAX_VALUE.toFloat()
                }

                val samples = floatBuf.copyOf(n)
                val energy = rms(samples, n)

                if (energy >= ENERGY_THRESHOLD) {
                    hangover = ENERGY_HANGOVER_BUFFERS
                } else if (hangover > 0) {
                    hangover--
                } else {
                    continue
                }

                nativeAcceptWaveform(streamPtr, samples, SAMPLE_RATE)

                while (nativeIsStreamReady(spotterPtr, streamPtr)) {
                    nativeDecodeStream(spotterPtr, streamPtr)
                    val keyword = nativeGetResult(spotterPtr, streamPtr)
                    if (keyword.isNotEmpty()) {
                        Log.i(TAG, "WakeWordEngine: detected '$keyword'")
                        nativeResetStream(spotterPtr, streamPtr)
                        try {
                            onDetected(keyword)
                        } catch (e: Exception) {
                            Log.e(TAG, "WakeWordEngine: callback error", e)
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "WakeWordEngine: detection error", e)
            onError?.invoke("Detection loop error: ${e.message}")
        } finally {
            try { recorder.stop() } catch (_: IllegalStateException) {}
            recorder.release()
            audioRecord = null
            nativeDestroyStream(streamPtr)
            isRunning.set(false)
            Log.i(TAG, "WakeWordEngine: detection loop stopped")
        }
    }

    private fun rms(samples: FloatArray, n: Int): Float {
        var sum = 0f
        for (i in 0 until n) {
            sum += samples[i] * samples[i]
        }
        return sqrt(sum / n)
    }

    // ── Native methods ──────────────────────────────────────────────────────

    private external fun nativeCreateSpotter(modelDir: String, keywords: String, numThreads: Int): Long

    private external fun nativeDestroySpotter(ptr: Long)

    private external fun nativeCreateStream(ptr: Long): Long

    private external fun nativeDestroyStream(streamPtr: Long)

    private external fun nativeAcceptWaveform(
        streamPtr: Long, samples: FloatArray, sampleRate: Int
    )

    private external fun nativeIsStreamReady(ptr: Long, streamPtr: Long): Boolean

    private external fun nativeDecodeStream(ptr: Long, streamPtr: Long)

    private external fun nativeGetResult(ptr: Long, streamPtr: Long): String

    private external fun nativeResetStream(ptr: Long, streamPtr: Long)
}
