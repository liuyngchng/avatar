package com.rd.avatar.asr

import android.content.Context
import android.util.Log
import java.io.File

class SherpaAsrEngine(private val context: Context) {

    companion object {
        private const val TAG = "RobotCompanion"
        private const val MODEL_DIR = "models/asr"
        private const val MODEL_FILE = "model.int8.onnx"
        private const val TOKENS_FILE = "tokens.txt"
    }

    private var statePtr: Long = 0
    private var isInitialized = false

    fun initialize(): Boolean {
        if (isInitialized) return true

        val modelDir = File(context.filesDir, MODEL_DIR)
        val modelFile = File(modelDir, MODEL_FILE)
        val tokensFile = File(modelDir, TOKENS_FILE)

        if (!modelFile.exists()) {
            Log.e(TAG, "ASR: model file not found: ${modelFile.absolutePath}")
            return false
        }
        if (!tokensFile.exists()) {
            Log.e(TAG, "ASR: tokens file not found: ${tokensFile.absolutePath}")
            return false
        }

        Log.i(TAG, "ASR: initializing with model=${modelFile.absolutePath}")
        statePtr = nativeCreateRecognizer(
            modelFile.absolutePath,
            tokensFile.absolutePath
        )

        isInitialized = statePtr != 0L
        if (isInitialized) {
            Log.i(TAG, "ASR: initialized OK")
        } else {
            Log.e(TAG, "ASR: failed to create recognizer")
        }
        return isInitialized
    }

    fun acceptWaveform(samples: FloatArray) {
        if (!isInitialized) return
        nativeAcceptWaveform(statePtr, samples)
    }

    fun getPendingText(): String {
        if (!isInitialized) return ""
        return nativeGetText(statePtr)
    }

    fun inputFinished(): String {
        if (!isInitialized) return ""
        return nativeInputFinished(statePtr)
    }

    val isReady: Boolean
        get() = isInitialized

    fun destroy() {
        if (isInitialized) {
            nativeDestroyRecognizer(statePtr)
            statePtr = 0
            isInitialized = false
        }
    }

    private external fun nativeCreateRecognizer(
        modelPath: String,
        tokensPath: String
    ): Long

    private external fun nativeAcceptWaveform(
        ptr: Long,
        samples: FloatArray
    )

    private external fun nativeGetText(ptr: Long): String

    private external fun nativeInputFinished(ptr: Long): String

    private external fun nativeDestroyRecognizer(ptr: Long)
}
