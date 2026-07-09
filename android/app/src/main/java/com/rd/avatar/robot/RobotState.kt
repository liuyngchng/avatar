package com.rd.avatar.robot

/**
 * Core data model for the robot companion.
 */

/** Top-level behavior state (FSM) */
enum class RobotMode {
    /** Idle, waiting for interaction. Eyes wander, occasional blinks. */
    IDLE,

    /** User tapped or said wake word — waiting for speech input. */
    LISTENING,

    /** Robot is speaking (TTS active). Mouth animates. */
    SPEAKING,

    /** Human face detected — engaged, eyes follow face. */
    WATCHING,

    /** Processing request (e.g. waiting on LLM response). */
    THINKING
}

/** Emotional state — drives expression and tone */
enum class Emotion(val intensity: Float) {
    NEUTRAL(0.5f),
    HAPPY(0.8f),
    CURIOUS(0.6f),
    SURPRISED(0.9f),
    SHY(0.4f),
    SLEEPY(0.3f),
    SAD(0.3f)
}

/**
 * Current robot state, consumed by UI and behavior engine.
 */
@androidx.compose.runtime.Stable
data class RobotState(
    val mode: RobotMode = RobotMode.IDLE,

    /** Detected face bounding box center, normalized 0..1, or null */
    val faceTargetX: Float? = null,
    val faceTargetY: Float? = null,

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

    /** Time since last face detection in ms */
    val msSinceLastFace: Long = 0L
)
