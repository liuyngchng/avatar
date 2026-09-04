package com.rd.avatar.audio

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Singleton coordinating wake word detection state between [VoiceService] and the UI layer.
 *
 * VoiceService runs continuously while the user has the wake word toggle enabled.
 * Conversations only pause/resume KWS — they never kill the service.
 *
 * Lifecycle of a wake-word-triggered voice session:
 *   1. VoiceService detects wake word → stops KWS engine → notifyWakeWord()
 *   2. MainActivity receives event → notifyPause() (redundant safety, KWS already stopped)
 *   3. MainActivity starts ASR recording (mic now free, KWS paused)
 *   4. ASR → LLM → TTS → voice flow completes
 *   5. MainActivity calls notifyVoiceFlowDone()
 *   6. VoiceService receives resumeSignal → resumes KWS engine
 */
object WakeWordManager {

    private val _wakeEvents = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val wakeEvents: SharedFlow<Unit> = _wakeEvents.asSharedFlow()

    private val _isRunning = MutableStateFlow(false)
    val isRunning: StateFlow<Boolean> = _isRunning.asStateFlow()

    /** Signal emitted when the voice flow completes and KWS should resume. */
    private val _resumeSignal = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val resumeSignal: SharedFlow<Unit> = _resumeSignal.asSharedFlow()

    /** Signal emitted when KWS should pause (e.g. a conversation is starting and
     *  needs the microphone for ASR). Unlike stopping the service, pausing only
     *  releases the mic and leaves the service alive so it can resume later. */
    private val _pauseSignal = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val pauseSignal: SharedFlow<Unit> = _pauseSignal.asSharedFlow()

    // ── Adaptive debounce state ────────────────────────────────────────────

    private const val BASE_DEBOUNCE_MS = 5000L
    private const val MAX_DEBOUNCE_MS = 120_000L
    // Cap shift exponent to prevent overflow: 1L << 62 is safe; 1L << 63 = Long.MIN_VALUE.
    private const val MAX_SHIFT = 62
    private var consecutiveFalseTriggers = 0

    /** Current debounce window based on recent false-trigger history. */
    val currentDebounceMs: Long
        get() {
            if (consecutiveFalseTriggers == 0) return BASE_DEBOUNCE_MS
            val shift = consecutiveFalseTriggers.coerceAtMost(MAX_SHIFT)
            val doubled = BASE_DEBOUNCE_MS * (1L shl shift)
            return doubled.coerceAtMost(MAX_DEBOUNCE_MS)
        }

    /** Called by VoiceService when the wake word is detected. */
    fun notifyWakeWord() {
        _wakeEvents.tryEmit(Unit)
    }

    /**
     * Called by MainViewModel after a wake-word-triggered voice session
     * completes successfully (ASR produced meaningful text).
     * Resets the adaptive debounce counter.
     */
    fun notifyProductiveWake() {
        if (consecutiveFalseTriggers > 0) {
            consecutiveFalseTriggers = 0
        }
    }

    /**
     * Called by MainViewModel when a wake-word-triggered session produced
     * no meaningful speech (false trigger). Increases the debounce window.
     */
    fun notifyFalseTrigger() {
        consecutiveFalseTriggers++
    }

    /** Called by MainViewModel when the voice flow (ASR→LLM→TTS) has completed. */
    fun notifyVoiceFlowDone() {
        _resumeSignal.tryEmit(Unit)
    }

    /** Called by MainViewModel to pause KWS (e.g. conversation starting, mic needed for ASR). */
    fun notifyPause() {
        _pauseSignal.tryEmit(Unit)
    }

    /** Called by VoiceService to update the running state. */
    fun setRunning(running: Boolean) {
        _isRunning.value = running
    }
}
