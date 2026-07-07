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
import com.mobilerobot.app.robot.Emotion
import com.mobilerobot.app.robot.RobotMode
import com.mobilerobot.app.robot.RobotState
import kotlinx.coroutines.delay
import kotlin.math.*
import kotlin.random.Random

// ─── Color Palette ────────────────────────────────────────────
private val ColorBg = Color(0xFF1A1A2E)
private val ColorFaceFill = Color(0xFFF5F0EB)
private val ColorFaceBorder = Color(0xFF444477)
private val ColorEyeSocket = Color(0xFFFFFFFF)
private val ColorPupil = Color(0xFF16213E)
private val ColorIris = Color(0xFF0F3460)
private val ColorHighlight = Color(0xFFFFFFFF)
private val ColorMouth = Color(0xFFE94560)
private val ColorBlush = Color(0x55E94560)
private val ColorEyebrow = Color(0xFF2D2D44)

// ─── Geometry Constants (relative to canvas size) ─────────────
private const val FACE_RADIUS_FRACTION = 0.40f     // round face radius
private const val FACE_CENTER_Y_FRACTION = 0.46f    // face vertical center
private const val EYE_Y_FRACTION = 0.36f            // eyes vertical position
private const val EYE_SPACING_FRACTION = 0.22f      // distance from center to each eye
private const val EYE_SOCKET_W_FRACTION = 0.18f     // socket width
private const val EYE_SOCKET_H_FRACTION = 0.24f     // socket height
private const val PUPIL_RADIUS_FRACTION = 0.07f     // pupil size
private const val PUPIL_MAX_OFFSET_X_FRACTION = 0.07f // max pupil horizontal travel
private const val PUPIL_MAX_OFFSET_Y_FRACTION = 0.04f // max pupil vertical travel
private const val IRIS_RADIUS_FRACTION = 0.09f      // iris radius
private const val MOUTH_Y_FRACTION = 0.64f          // mouth vertical position
private const val MOUTH_W_FRACTION = 0.16f          // mouth half-width
private const val EYEBROW_Y_OFFSET_FRACTION = 0.075f // eyebrow above eye center
private const val EYEBROW_LENGTH_FRACTION = 0.14f    // eyebrow half-length
private const val EYEBROW_THICKNESS = 5f

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

    // Speaking mouth oscillation
    val speakMouth = remember { Animatable(0f) }

    // Thinking eye animation (eyes look up, dart around)
    val thinkPhase = remember { Animatable(0f) }

    // Idle eye wandering animation
    LaunchedEffect(state.faceTargetX) {
        if (state.faceTargetX == null) {
            while (true) {
                idleWander.animateTo(
                    targetValue = Random.nextFloat() * 2f - 1f,
                    animationSpec = tween(2000 + Random.nextInt(1500), easing = FastOutSlowInEasing)
                )
            }
        }
    }

    // Blinking animation
    LaunchedEffect(state.blinkTrigger) {
        if (state.blinkTrigger > 0L) {
            blinkProgress.snapTo(0f)
            blinkProgress.animateTo(1f, tween(80))
            delay(120)
            blinkProgress.animateTo(0f, tween(80))
        }
    }

    // Speaking: oscillate mouth open/close
    LaunchedEffect(state.isSpeaking) {
        if (state.isSpeaking) {
            while (true) {
                speakMouth.animateTo(1f, tween(120))
                speakMouth.animateTo(0.2f, tween(120))
            }
        } else {
            speakMouth.snapTo(0f)
        }
    }

    // Thinking: eyes look up + dart, phase oscillates
    LaunchedEffect(state.mode) {
        if (state.mode == RobotMode.THINKING) {
            while (true) {
                thinkPhase.animateTo(1f, tween(800, easing = FastOutSlowInEasing))
                thinkPhase.animateTo(-1f, tween(800, easing = FastOutSlowInEasing))
            }
        } else {
            thinkPhase.snapTo(0f)
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
            val cy = size.height * FACE_CENTER_Y_FRACTION
            val faceRadius = size.width * FACE_RADIUS_FRACTION

            // ── Round face outline ──
            drawCircle(
                color = ColorFaceFill,
                radius = faceRadius,
                center = Offset(cx, cy)
            )
            drawCircle(
                color = ColorFaceBorder,
                radius = faceRadius,
                center = Offset(cx, cy),
                style = Stroke(width = 4f)
            )

            val eyeY = size.height * EYE_Y_FRACTION
            val mouthY = size.height * MOUTH_Y_FRACTION
            val leftEyeCx = cx - size.width * EYE_SPACING_FRACTION
            val rightEyeCx = cx + size.width * EYE_SPACING_FRACTION
            val socketW = size.width * EYE_SOCKET_W_FRACTION
            val socketH = size.height * EYE_SOCKET_H_FRACTION
            val pupilRadius = size.width * PUPIL_RADIUS_FRACTION
            val irisRadius = size.width * IRIS_RADIUS_FRACTION
            val maxPupilOffsetX = size.width * PUPIL_MAX_OFFSET_X_FRACTION
            val maxPupilOffsetY = size.width * PUPIL_MAX_OFFSET_Y_FRACTION
            val mouthHalfW = size.width * MOUTH_W_FRACTION
            val eyebrowHalfLen = size.width * EYEBROW_LENGTH_FRACTION
            val eyebrowYOff = size.width * EYEBROW_Y_OFFSET_FRACTION

            // Thinking: override pupil to look up
            val isThinking = state.mode == RobotMode.THINKING
            val (pupilDx, pupilDy) = if (isThinking) {
                (thinkPhase.value * maxPupilOffsetX * 0.3f) to (-maxPupilOffsetY * 0.9f)
            } else {
                computePupilOffset(
                    targetX, targetY, state.faceTargetX != null,
                    idleWander.value, maxPupilOffsetX, maxPupilOffsetY
                )
            }

            // ── Draw blush ──
            if (state.emotion == Emotion.HAPPY || state.emotion == Emotion.SHY) {
                drawBlush(leftEyeCx, eyeY, socketW, color = ColorBlush)
                drawBlush(rightEyeCx, eyeY, socketW, color = ColorBlush)
            }

            // ── Draw eyebrows ──
            val browEmotion = if (isThinking) Emotion.CURIOUS else state.emotion
            drawEyebrow(leftEyeCx, eyeY - eyebrowYOff, eyebrowHalfLen, browEmotion, left = true)
            drawEyebrow(rightEyeCx, eyeY - eyebrowYOff, eyebrowHalfLen, browEmotion, left = false)

            // ── Draw eyes ──
            drawEye(
                eyeCx = leftEyeCx, eyeY = eyeY,
                socketW = socketW, socketH = socketH,
                pupilDx = pupilDx, pupilDy = pupilDy,
                pupilRadius = pupilRadius, irisRadius = irisRadius,
                blinkAmount = blinkProgress.value,
                emotion = state.emotion
            )
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
                isSpeaking = state.isSpeaking,
                speakAmount = speakMouth.value
            )

            // ── Mode indicators ──
            when (state.mode) {
                RobotMode.LISTENING -> drawListeningIndicator(cx, cy + faceRadius + 28f)
                RobotMode.THINKING -> drawThinkingIndicator(cx, cy - faceRadius - 20f)
                else -> {}
            }

            // ── Face text below ──
            if (state.lastUserText != null && state.mode != RobotMode.IDLE) {
                drawContextBubble(cx, cy + faceRadius + 10f, state)
            }
        }
    }
}

private fun computePupilOffset(
    targetX: Float, targetY: Float,
    hasFace: Boolean,
    idleWander: Float,
    maxOffsetX: Float,
    maxOffsetY: Float
): Pair<Float, Float> {
    return if (hasFace) {
        val dx = (targetX - 0.5f) * maxOffsetX * 2f
        val dy = (targetY - 0.5f) * maxOffsetY * 2f
        dx.coerceIn(-maxOffsetX, maxOffsetX) to dy.coerceIn(-maxOffsetY, maxOffsetY)
    } else {
        val angle = idleWander * PI.toFloat()
        (cos(angle) * maxOffsetX * 0.4f) to (sin(angle * 1.7f) * maxOffsetY * 0.3f)
    }
}

// ─── Eye ──────────────────────────────────────────────────────

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

    val lidScale = when (emotion) {
        Emotion.SLEEPY -> 0.35f + blinkAmount * 0.65f
        Emotion.SHY -> 0.3f + blinkAmount * 0.7f
        Emotion.HAPPY -> 0.15f + blinkAmount * 0.85f
        else -> blinkAmount
    }

    // Socket (white of eye)
    if (lidScale < 0.99f) {
        drawOval(color = ColorEyeSocket, topLeft = socketTopLeft, size = socketSize)
    }

    // Iris
    val irisCenter = Offset(eyeCx + pupilDx * 1.5f, eyeY + pupilDy * 1.5f)
    if (lidScale < 0.95f) {
        drawCircle(color = ColorIris, radius = irisRadius, center = irisCenter)
    }

    // Pupil
    if (lidScale < 0.9f) {
        drawCircle(color = ColorPupil, radius = pupilRadius, center = irisCenter)
    }

    // Highlight
    if (lidScale < 0.85f) {
        val hlOffset = pupilRadius * 0.35f
        drawCircle(
            color = ColorHighlight,
            radius = pupilRadius * 0.28f,
            center = Offset(irisCenter.x - hlOffset, irisCenter.y - hlOffset)
        )
    }

    // Eyelid
    if (lidScale > 0.01f) {
        val lidHeight = socketH * lidScale
        val lidTop = eyeY - socketH / 2f
        drawRect(
            color = ColorFaceFill,
            topLeft = Offset(eyeCx - socketW / 2f - 4f, lidTop - 4f),
            size = Size(socketW + 8f, lidHeight + 4f)
        )
    }

    // Eye outline
    if (emotion != Emotion.HAPPY) {
        drawOval(
            color = ColorFaceBorder,
            topLeft = socketTopLeft,
            size = socketSize,
            style = Stroke(width = 3f)
        )
    }
}

// ─── Eyebrow ──────────────────────────────────────────────────

private fun DrawScope.drawEyebrow(
    eyeCx: Float, browY: Float,
    halfLen: Float,
    emotion: Emotion,
    left: Boolean
) {
    val sign = if (left) -1f else 1f
    val path = Path()

    when (emotion) {
        Emotion.HAPPY -> {
            // Raised, arched up
            path.moveTo(eyeCx - halfLen, browY + halfLen * 0.15f)
            path.quadraticBezierTo(
                eyeCx, browY - halfLen * 0.5f,
                eyeCx + halfLen, browY + halfLen * 0.15f
            )
        }
        Emotion.SAD -> {
            // Angled down toward center (worried)
            val innerLow = browY + halfLen * 0.5f
            path.moveTo(eyeCx - halfLen * sign, browY - halfLen * 0.2f)
            path.lineTo(eyeCx + halfLen * sign, innerLow)
        }
        Emotion.SURPRISED -> {
            // Raised high
            path.moveTo(eyeCx - halfLen, browY - halfLen * 0.6f)
            path.quadraticBezierTo(
                eyeCx, browY - halfLen * 0.8f,
                eyeCx + halfLen, browY - halfLen * 0.6f
            )
        }
        Emotion.CURIOUS -> {
            // One raised (left), one straight (right) — we draw same for both but left is higher
            val raise = if (left) halfLen * 0.5f else halfLen * 0.05f
            path.moveTo(eyeCx - halfLen, browY - raise)
            path.quadraticBezierTo(
                eyeCx, browY - raise - halfLen * 0.25f,
                eyeCx + halfLen, browY - raise
            )
        }
        Emotion.SLEEPY -> {
            // Drooping, slightly lowered
            path.moveTo(eyeCx - halfLen, browY + halfLen * 0.1f)
            path.lineTo(eyeCx + halfLen, browY + halfLen * 0.2f)
        }
        Emotion.SHY -> {
            // Slight shy arch
            path.moveTo(eyeCx - halfLen, browY)
            path.quadraticBezierTo(
                eyeCx, browY - halfLen * 0.3f,
                eyeCx + halfLen, browY
            )
        }
        else -> {
            // NEUTRAL: subtle arch
            path.moveTo(eyeCx - halfLen, browY)
            path.quadraticBezierTo(
                eyeCx, browY - halfLen * 0.2f,
                eyeCx + halfLen, browY
            )
        }
    }

    drawPath(
        path = path,
        color = ColorEyebrow,
        style = Stroke(width = EYEBROW_THICKNESS, cap = androidx.compose.ui.graphics.StrokeCap.Round)
    )
}

// ─── Blush ────────────────────────────────────────────────────

private fun DrawScope.drawBlush(cx: Float, eyeY: Float, eyeW: Float, color: Color) {
    val blushY = eyeY + eyeW * 0.6f
    drawCircle(
        color = color,
        radius = eyeW * 0.55f,
        center = Offset(cx, blushY)
    )
}

// ─── Mouth ────────────────────────────────────────────────────

private fun DrawScope.drawMouth(
    cx: Float, mouthY: Float,
    halfWidth: Float,
    emotion: Emotion,
    isSpeaking: Boolean,
    speakAmount: Float
) {
    val mouthPath = Path()
    val speakOpen = halfWidth * 0.7f * speakAmount // additional opening when speaking

    when (emotion) {
        Emotion.HAPPY -> {
            val yOff = halfWidth * 0.9f + speakOpen * 0.6f
            mouthPath.moveTo(cx - halfWidth * 1.2f, mouthY)
            mouthPath.quadraticBezierTo(cx, mouthY + yOff, cx + halfWidth * 1.2f, mouthY)
        }
        Emotion.SURPRISED -> {
            val r = halfWidth * 0.6f + speakOpen
            mouthPath.addOval(
                androidx.compose.ui.geometry.Rect(
                    center = Offset(cx, mouthY + r * 0.3f),
                    radius = r
                )
            )
        }
        Emotion.SAD -> {
            mouthPath.moveTo(cx - halfWidth * 0.8f, mouthY)
            mouthPath.quadraticBezierTo(
                cx, mouthY - halfWidth * 0.5f - speakOpen * 0.3f,
                cx + halfWidth * 0.8f, mouthY
            )
        }
        Emotion.CURIOUS -> {
            val r = halfWidth * 0.35f + speakOpen * 0.5f
            drawCircle(ColorMouth, r, Offset(cx, mouthY))
        }
        Emotion.SLEEPY -> {
            val dy = halfWidth * 0.3f + speakOpen * 0.5f
            mouthPath.moveTo(cx - halfWidth * 0.5f, mouthY)
            mouthPath.quadraticBezierTo(cx, mouthY + dy, cx + halfWidth * 0.5f, mouthY)
        }
        Emotion.SHY -> {
            val dy = halfWidth * 0.15f + speakOpen * 0.3f
            mouthPath.moveTo(cx - halfWidth * 0.5f, mouthY)
            mouthPath.cubicTo(
                cx - halfWidth * 0.25f, mouthY - dy,
                cx + halfWidth * 0.25f, mouthY + dy,
                cx + halfWidth * 0.5f, mouthY
            )
        }
        else -> {
            val dy = halfWidth * 0.25f + speakOpen * 0.5f
            mouthPath.moveTo(cx - halfWidth * 0.7f, mouthY)
            mouthPath.quadraticBezierTo(cx, mouthY + dy, cx + halfWidth * 0.7f, mouthY)
        }
    }

    val filled = emotion == Emotion.SURPRISED || (isSpeaking && speakAmount > 0.4f)
    drawPath(
        mouthPath,
        ColorMouth,
        style = if (filled) androidx.compose.ui.graphics.drawscope.Fill else Stroke(width = 4f)
    )
}

// ─── Mode Indicators ──────────────────────────────────────────

private fun DrawScope.drawListeningIndicator(cx: Float, y: Float) {
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

/** Thinking indicator — three dots pulsing near top of head */
private fun DrawScope.drawThinkingIndicator(cx: Float, y: Float) {
    val dotRadius = 5f
    val spacing = 14f
    // Three dots in a horizontal row
    for (i in -1..1) {
        drawCircle(
            color = ColorMouth.copy(alpha = 0.6f),
            radius = dotRadius,
            center = Offset(cx + i * spacing, y)
        )
    }
}

/** Show last user text or response as a subtle bubble below the face */
private fun DrawScope.drawContextBubble(cx: Float, y: Float, state: RobotState) {
    // Simple text indicator — just a small colored dot showing "I heard you"
    val active = state.lastUserText != null
    if (active) {
        val alpha = when (state.mode) {
            RobotMode.THINKING -> 0.4f
            RobotMode.SPEAKING -> 0.9f
            RobotMode.LISTENING -> 0.7f
            else -> 0.5f
        }
        val text = when (state.mode) {
            RobotMode.LISTENING -> "正在听..."
            RobotMode.THINKING -> "思考中..."
            RobotMode.SPEAKING -> "正在说..."
            else -> ""
        }
        // We can't easily draw text in Canvas without TextMeasurer,
        // but the mode indicator above already shows the state.
        // Keep a subtle glow ring around the face for thinking/speaking
        if (state.mode == RobotMode.THINKING || state.mode == RobotMode.SPEAKING) {
            val color = if (state.mode == RobotMode.THINKING)
                Color(0xFF66AAFF).copy(alpha = alpha)
            else
                ColorMouth.copy(alpha = alpha)
            drawCircle(
                color = color,
                radius = size.width * FACE_RADIUS_FRACTION + 6f,
                center = Offset(cx, size.height * FACE_CENTER_Y_FRACTION),
                style = Stroke(width = 3f)
            )
        }
    }
}
