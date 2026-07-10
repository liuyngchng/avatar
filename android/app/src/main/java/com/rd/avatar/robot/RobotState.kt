package com.rd.avatar.robot

/**
 * Core data model for the stick-figure companion.
 * Minimal state — no face tracking, no camera always-on.
 */

/** Top-level behavior state (FSM) */
enum class RobotMode {
    /** Idle, waiting for interaction. Stick figure does random goofy antics. */
    IDLE,

    /** User tapped or said wake word — waiting for speech input. */
    LISTENING,

    /** Stick figure is speaking (TTS active). Mouth + arm gestures animate. */
    SPEAKING,

    /** Processing request (e.g. waiting on LLM response). */
    THINKING,

    /** Camera is active (rear camera, on-demand). Stick figure holds a "camera" pose. */
    LOOKING
}

/** Emotional state — drives expression */
enum class Emotion(val intensity: Float) {
    NEUTRAL(0.5f),
    HAPPY(0.8f),
    CURIOUS(0.6f),
    SURPRISED(0.9f),
    SHY(0.4f),
    SLEEPY(0.3f),
    SAD(0.3f),

    /** Goofy / silly mood — for random antics */
    GOOFY(0.9f)
}

/**
 * Current stick figure state, consumed by UI and behavior engine.
 */
@androidx.compose.runtime.Stable
data class RobotState(
    val mode: RobotMode = RobotMode.IDLE,

    /** Current emotion */
    val emotion: Emotion = Emotion.NEUTRAL,

    /** Whether TTS is currently producing audio */
    val isSpeaking: Boolean = false,

    /** Last recognized user utterance */
    val lastUserText: String? = null,

    /** Response text to speak */
    val responseText: String? = null,

    /** Blink trigger — UI toggles each time this changes */
    val blinkTrigger: Long = 0L,

    /** Random antic trigger — increments to make the stick figure do something goofy */
    val anticTrigger: Long = 0L,

    /** When LOOKING: a description of what the camera saw (filled by LLM or local logic) */
    val cameraObservation: String? = null
)
