package com.rd.avatar.tts

import android.content.Context
import android.util.Log
import java.io.File

class SherpaTtsEngine(private val context: Context) {

    companion object {
        private const val TAG = "RobotCompanion"
        private const val MODEL_DIR = "models/tts"
        private const val ACOUSTIC_MODEL = "model.onnx"
        private const val VOCODER_MODEL = "vocos.onnx"
        private const val TOKENS_FILE = "tokens.txt"
        private const val LEXICON_FILE = "lexicon.txt"

        const val DEFAULT_SPEED = 1.0f
        const val DEFAULT_SAMPLE_RATE = 22050
    }

    private var statePtr: Long = 0
    private var isInitialized = false

    fun initialize(): Boolean {
        if (isInitialized) return true

        val modelDir = File(context.filesDir, MODEL_DIR)
        val acousticModel = File(modelDir, ACOUSTIC_MODEL)
        val vocoder = File(modelDir, VOCODER_MODEL)
        val tokens = File(modelDir, TOKENS_FILE)
        val lexicon = File(modelDir, LEXICON_FILE)

        if (!acousticModel.exists() || !vocoder.exists() || !tokens.exists() || !lexicon.exists()) {
            Log.e(TAG, "TTS: missing model files in ${modelDir.absolutePath}")
            return false
        }

        val numThreads = Runtime.getRuntime().availableProcessors().coerceIn(2, 4)

        Log.i(TAG, "TTS: initializing with numThreads=$numThreads")
        statePtr = nativeCreateTts(
            acousticModel.absolutePath,
            vocoder.absolutePath,
            tokens.absolutePath,
            lexicon.absolutePath,
            numThreads
        )

        isInitialized = statePtr != 0L
        if (isInitialized) {
            Log.i(TAG, "TTS: initialized OK, sample_rate=${getSampleRate()}")
        } else {
            Log.e(TAG, "TTS: failed to create engine")
        }
        return isInitialized
    }

    fun synthesize(text: String, speed: Float = DEFAULT_SPEED, sid: Int = 0): FloatArray? {
        if (!isInitialized) return null

        return try {
            nativeSynthesize(statePtr, text, speed, sid)
        } catch (e: Exception) {
            Log.e(TAG, "TTS: synthesis failed: ${e.message}")
            null
        }
    }

    fun getSampleRate(): Int {
        if (!isInitialized) return DEFAULT_SAMPLE_RATE
        return nativeGetSampleRate(statePtr)
    }

    val isReady: Boolean
        get() = isInitialized

    fun destroy() {
        if (isInitialized) {
            nativeDestroyTts(statePtr)
            statePtr = 0
            isInitialized = false
        }
    }

    private external fun nativeCreateTts(
        acousticModelPath: String,
        vocoderPath: String,
        tokensPath: String,
        lexiconPath: String,
        numThreads: Int
    ): Long

    private external fun nativeSynthesize(
        ptr: Long,
        text: String,
        speed: Float,
        sid: Int
    ): FloatArray

    private external fun nativeGetSampleRate(ptr: Long): Int

    private external fun nativeDestroyTts(ptr: Long)
}
