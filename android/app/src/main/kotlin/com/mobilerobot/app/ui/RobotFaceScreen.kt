package com.mobilerobot.app.ui

import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import com.mobilerobot.app.camera.FaceDetectionResult
import com.mobilerobot.app.robot.Emotion
import com.mobilerobot.app.robot.RobotMode
import com.mobilerobot.app.robot.RobotState
import kotlinx.coroutines.delay
import kotlin.math.*
import kotlin.random.Random

// ─── Color Palette ────────────────────────────────────────────
private val ColorBg = Color(0xFF1A1A2E)
private val ColorEyeSocket = Color(0xFFF0F0F0)
private val ColorPupil = Color(0xFF16213E)
private val ColorIris = Color(0xFF0F3460)
private val ColorHighlight = Color(0xFFFFFFFF)
private val ColorMouth = Color(0xFFE94560)
private val ColorBlush = Color(0x55E94560)
private val ColorGlow = Color(0x22E94560)

// ─── Geometry Constants (relative to canvas size) ─────────────
private const val EYE_Y_FRACTION = 0.38f       // eyes vertical position
private const val EYE_SPACING_FRACTION = 0.22f  // distance from center to each eye
private const val EYE_SOCKET_W_FRACTION = 0.18f // socket width
private const val EYE_SOCKET_H_FRACTION = 0.22f // socket height
private const val PUPIL_RADIUS_FRACTION = 0.07f // pupil size
private const val PUPIL_MAX_OFFSET_FRACTION = 0.04f // max pupil travel
private const val IRIS_RADIUS_FRACTION = 0.09f  // iris radius
private const val MOUTH_Y_FRACTION = 0.68f      // mouth vertical position
private const val MOUTH_W_FRACTION = 0.18f      // mouth half-width

/**
 * Main robot face composable.
 *
 * @param state current robot state (drives expression + eye tracking)
 * @param onTap called when user taps the face
 */
@Composable
fun RobotFaceScreen(
    state: RobotState,
    onTap: () -> Unit = {},
    onLongPress: () -> Unit = {}
) {
    // Smoothly interpolate face target for eye movement
    val targetX by animateFloatAsState(
        targetValue = state.faceTargetX ?: 0.5f,
        animationSpec = tween(200, easing = FastOutSlowInEasing)
    )
    val targetY by animateFloatAsState(
        targetValue = state.faceTargetY ?: 0.5f,
        animationSpec = tween(200, easing = FastOutSlowInEasing)
    )

    // Idle wander when no face detected
    val idleWander = remember { Animatable(0f) }
    val blinkProgress = remember { Animatable(0f) }

    // Idle eye wandering animation
    LaunchedEffect(state.faceTargetX) {
        if (state.faceTargetX == null) {
            // No face — eyes wander
            while (true) {
                idleWander.animateTo(
                    targetValue = Random.nextFloat() * 2f - 1f,
                    animationSpec = tween(2000 + Random.nextInt(1500), easing = FastOutSlowInEasing)
                )
            }
        }
    }

    // Blinking animation — triggers when blinkTrigger changes
    LaunchedEffect(state.blinkTrigger) {
        if (state.blinkTrigger > 0L) {
            blinkProgress.snapTo(0f)
            blinkProgress.animateTo(1f, tween(80))
            delay(120)
            blinkProgress.animateTo(0f, tween(80))
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(ColorBg)
            .pointerInput(Unit) {
                detectTapGestures(
                    onTap = { onTap() },
                    onLongPress = { onLongPress() }
                )
            }
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val cx = size.width / 2f
            val cy = size.height / 2f
            val eyeY = size.height * EYE_Y_FRACTION
            val mouthY = size.height * MOUTH_Y_FRACTION

            // Compute eye socket positions
            val leftEyeCx = cx - size.width * EYE_SPACING_FRACTION
            val rightEyeCx = cx + size.width * EYE_SPACING_FRACTION
            val socketW = size.width * EYE_SOCKET_W_FRACTION
            val socketH = size.height * EYE_SOCKET_H_FRACTION
            val pupilRadius = size.width * PUPIL_RADIUS_FRACTION
            val irisRadius = size.width * IRIS_RADIUS_FRACTION
            val maxPupilOffset = size.width * PUPIL_MAX_OFFSET_FRACTION
            val mouthHalfW = size.width * MOUTH_W_FRACTION

            // Compute pupil offset from face target
            val (pupilDx, pupilDy) = computePupilOffset(
                targetX, targetY, state.faceTargetX != null, idleWander.value, maxPupilOffset
            )

            // ── Draw blush (behind eyes, for certain emotions) ──
            if (state.emotion == Emotion.HAPPY || state.emotion == Emotion.SHY) {
                drawBlush(leftEyeCx, eyeY, socketW, color = ColorBlush)
                drawBlush(rightEyeCx, eyeY, socketW, color = ColorBlush)
            }

            // ── Draw left eye ──
            drawEye(
                eyeCx = leftEyeCx, eyeY = eyeY,
                socketW = socketW, socketH = socketH,
                pupilDx = pupilDx, pupilDy = pupilDy,
                pupilRadius = pupilRadius, irisRadius = irisRadius,
                blinkAmount = blinkProgress.value,
                emotion = state.emotion
            )

            // ── Draw right eye ──
            drawEye(
                eyeCx = rightEyeCx, eyeY = eyeY,
                socketW = socketW, socketH = socketH,
                pupilDx = pupilDx, pupilDy = pupilDy,
                pupilRadius = pupilRadius, irisRadius = irisRadius,
                blinkAmount = blinkProgress.value,
                emotion = state.emotion
            )

            // ── Draw mouth ──
            drawMouth(
                cx = cx, mouthY = mouthY,
                halfWidth = mouthHalfW,
                emotion = state.emotion,
                isSpeaking = state.isSpeaking
            )

            // ── Mode indicator ──
            if (state.mode == RobotMode.LISTENING) {
                drawListeningIndicator(cx, size.height * 0.85f)
            }

            // ── Debug: face target crosshair ──
            // drawCircle(Color.Red, 10f, Offset(targetX * size.width, targetY * size.height))
        }
    }
}

/**
 * Compute pupil offset from the center of each eye socket.
 */
private fun computePupilOffset(
    targetX: Float,       // 0..1, face center X
    targetY: Float,       // 0..1, face center Y
    hasFace: Boolean,
    idleWander: Float,
    maxOffset: Float
): Pair<Float, Float> {
    return if (hasFace) {
        // Map face position to pupil offset.
        // Face at center (0.5, 0.5) → pupils centered (0, 0)
        // Face at left → pupils look left (negative dx)
        val dx = (targetX - 0.5f) * maxOffset * 2f
        val dy = (targetY - 0.5f) * maxOffset * 2f
        dx.coerceIn(-maxOffset, maxOffset) to dy.coerceIn(-maxOffset, maxOffset)
    } else {
        // Idle wander: sinusoidal motion
        val angle = idleWander * PI.toFloat()
        (cos(angle) * maxOffset * 0.4f) to (sin(angle * 1.7f) * maxOffset * 0.3f)
    }
}

// ─── Drawing Functions ────────────────────────────────────────

/**
 * Draw a single eye: socket, iris, pupil, highlight, eyelid.
 */
private fun DrawScope.drawEye(
    eyeCx: Float, eyeY: Float,
    socketW: Float, socketH: Float,
    pupilDx: Float, pupilDy: Float,
    pupilRadius: Float, irisRadius: Float,
    blinkAmount: Float,
    emotion: Emotion
) {
    val socketSize = Size(socketW, socketH)
    val socketTopLeft = Offset(eyeCx - socketW / 2f, eyeY - socketH / 2f)

    // Eyelid scale — 0 = fully open, 1 = fully closed
    val lidScale = when (emotion) {
        Emotion.SLEEPY -> 0.35f + blinkAmount * 0.65f
        Emotion.SHY -> 0.3f + blinkAmount * 0.7f
        Emotion.HAPPY -> 0.15f + blinkAmount * 0.85f // happy squint
        else -> blinkAmount
    }

    // --- Socket (white of eye) ---
    if (lidScale < 0.99f) {
        drawOval(
            color = ColorEyeSocket,
            topLeft = socketTopLeft,
            size = socketSize
        )
    }

    // --- Iris ---
    val irisCenter = Offset(
        eyeCx + pupilDx * 1.5f,
        eyeY + pupilDy * 1.5f
    )
    if (lidScale < 0.95f) {
        drawCircle(color = ColorIris, radius = irisRadius, center = irisCenter)
    }

    // --- Pupil ---
    if (lidScale < 0.9f) {
        drawCircle(color = ColorPupil, radius = pupilRadius, center = irisCenter)
    }

    // --- Eye highlight (specular reflection) ---
    if (lidScale < 0.85f) {
        val hlOffset = pupilRadius * 0.35f
        drawCircle(
            color = ColorHighlight,
            radius = pupilRadius * 0.28f,
            center = Offset(irisCenter.x - hlOffset, irisCenter.y - hlOffset)
        )
    }

    // --- Eyelid (covers top portion of the eye, creating blink effect) ---
    if (lidScale > 0.01f) {
        val lidHeight = socketH * lidScale
        val lidTop = eyeY - socketH / 2f
        drawRect(
            color = ColorBg,
            topLeft = Offset(eyeCx - socketW / 2f - 4f, lidTop - 4f),
            size = Size(socketW + 8f, lidHeight + 4f)
        )
    }

    // --- Eye outline ---
    if (emotion != Emotion.HAPPY) { // happy eyes use a curved outline instead
        drawOval(
            color = Color(0xFF333355),
            topLeft = socketTopLeft,
            size = socketSize,
            style = Stroke(width = 3f)
        )
    }
}

/**
 * Draw blush circles on cheeks.
 */
private fun DrawScope.drawBlush(cx: Float, eyeY: Float, eyeW: Float, color: Color) {
    val blushY = eyeY + eyeW * 0.6f
    drawCircle(
        color = color,
        radius = eyeW * 0.55f,
        center = Offset(cx, blushY)
    )
}

/**
 * Draw the mouth — shape depends on emotion and speaking state.
 */
private fun DrawScope.drawMouth(
    cx: Float, mouthY: Float,
    halfWidth: Float,
    emotion: Emotion,
    isSpeaking: Boolean
) {
    val mouthPath = Path()

    when (emotion) {
        Emotion.HAPPY -> {
            // Wide smile: upward arc
            mouthPath.moveTo(cx - halfWidth * 1.2f, mouthY)
            mouthPath.quadraticBezierTo(
                cx, mouthY + halfWidth * 0.9f,
                cx + halfWidth * 1.2f, mouthY
            )
        }
        Emotion.SURPRISED -> {
            // Open round mouth
            val openR = halfWidth * 0.6f
            mouthPath.addOval(
                androidx.compose.ui.geometry.Rect(
                    center = Offset(cx, mouthY + openR * 0.3f),
                    radius = openR
                )
            )
        }
        Emotion.SAD -> {
            // Downward arc
            mouthPath.moveTo(cx - halfWidth * 0.8f, mouthY)
            mouthPath.quadraticBezierTo(
                cx, mouthY - halfWidth * 0.5f,
                cx + halfWidth * 0.8f, mouthY
            )
        }
        Emotion.CURIOUS -> {
            // Small 'o'
            drawCircle(ColorMouth, halfWidth * 0.35f, Offset(cx, mouthY))
        }
        Emotion.SLEEPY -> {
            // Slightly open drooping mouth
            val dy = halfWidth * 0.3f
            mouthPath.moveTo(cx - halfWidth * 0.5f, mouthY)
            mouthPath.quadraticBezierTo(
                cx, mouthY + dy,
                cx + halfWidth * 0.5f, mouthY
            )
        }
        Emotion.SHY -> {
            // Small wavy mouth
            val dy = halfWidth * 0.15f
            mouthPath.moveTo(cx - halfWidth * 0.5f, mouthY)
            mouthPath.cubicTo(
                cx - halfWidth * 0.25f, mouthY - dy,
                cx + halfWidth * 0.25f, mouthY + dy,
                cx + halfWidth * 0.5f, mouthY
            )
        }
        else -> {
            // NEUTRAL: slight smile
            val dy = halfWidth * 0.25f
            mouthPath.moveTo(cx - halfWidth * 0.7f, mouthY)
            mouthPath.quadraticBezierTo(
                cx, mouthY + dy,
                cx + halfWidth * 0.7f, mouthY
            )
        }
    }

    // If speaking, open the mouth more by scaling it vertically
    val mouthColor = if (isSpeaking) ColorMouth else Color(0xFFCC4466)
    val mouthStyle = if (emotion == Emotion.SURPRISED || isSpeaking) {
        androidx.compose.ui.graphics.drawscope.Fill
    } else {
        Stroke(width = 4f)
    }

    if (emotion != Emotion.CURIOUS) {
        drawPath(mouthPath, mouthColor, style = mouthStyle)
    }
}

/**
 * Draw a pulsing ring to indicate listening mode.
 */
private fun DrawScope.drawListeningIndicator(cx: Float, y: Float) {
    // Simple pulsing dots below the mouth
    val radii = listOf(6f, 10f, 6f)
    val offsets = listOf(-20f, 0f, 20f)
    for (i in radii.indices) {
        drawCircle(
            color = ColorMouth.copy(alpha = 0.7f),
            radius = radii[i],
            center = Offset(cx + offsets[i], y)
        )
    }
}
