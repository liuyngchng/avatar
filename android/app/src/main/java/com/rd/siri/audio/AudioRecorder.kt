package com.rd.siri.audio

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import java.util.concurrent.atomic.AtomicBoolean

class AudioRecorder(private val context: Context) {

    companion object {
        const val SAMPLE_RATE = 16000
        const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
        const val BUFFER_SIZE_FACTOR = 4

        fun isPermissionGranted(context: Context): Boolean =
            ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
    }

    private var audioRecord: AudioRecord? = null
    private val isRecording = AtomicBoolean(false)
    private val bufferSize: Int = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
        .let { it * BUFFER_SIZE_FACTOR }

    @SuppressLint("MissingPermission")
    fun startRecording(): Flow<FloatArray> = flow {
        if (!isPermissionGranted(context)) {
            throw SecurityException("RECORD_AUDIO permission not granted")
        }

        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            SAMPLE_RATE,
            CHANNEL_CONFIG,
            AUDIO_FORMAT,
            bufferSize
        )

        val recorder = audioRecord ?: throw IllegalStateException("Failed to create AudioRecord")

        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            throw IllegalStateException("AudioRecord initialization failed")
        }

        isRecording.set(true)
        recorder.startRecording()

        val shortBuffer = ShortArray(bufferSize / 2)
        val floatBuffer = FloatArray(bufferSize / 2)

        try {
            while (isRecording.get()) {
                val readSize = recorder.read(shortBuffer, 0, shortBuffer.size)
                if (readSize > 0) {
                    for (i in 0 until readSize) {
                        floatBuffer[i] = shortBuffer[i].toFloat() / Short.MAX_VALUE.toFloat()
                    }
                    emit(floatBuffer.copyOf(readSize))
                } else if (readSize < 0) {
                    // read() returned error (e.g. AudioRecord was stopped)
                    break
                }
            }
        } finally {
            try { recorder.stop() } catch (_: IllegalStateException) {}
            recorder.release()
            audioRecord = null
            isRecording.set(false)
        }
    }.flowOn(Dispatchers.IO)

    fun stopRecording() {
        isRecording.set(false)
        // Stop the AudioRecord to unblock any pending read() call
        audioRecord?.stop()
    }

    val isRecordingActive: Boolean
        get() = isRecording.get() && audioRecord?.recordingState == AudioRecord.RECORDSTATE_RECORDING
}
