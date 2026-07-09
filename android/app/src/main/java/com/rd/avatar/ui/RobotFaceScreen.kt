package com.rd.avatar.ui

import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import com.rd.avatar.robot.Emotion
import com.rd.avatar.robot.RobotMode
import com.rd.avatar.robot.RobotState
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlin.math.*
import kotlin.random.Random

// ─── Color Palette ────────────────────────────────────────────
private val ColorBg = Color(0xFF1A1A2E)
private val ColorFaceFillLight = Color(0xFFFAF5F0)
private val ColorFaceFillMid   = Color(0xFFEBE3DB)
private val ColorFaceBorder = Color(0xFF444477)
private val ColorEyeSocket = Color(0xFFFFFFFF)
private val ColorPupil = Color(0xFF16213E)
private val ColorIris = Color(0xFF0F3460)
private val ColorHighlight = Color(0xFFFFFFFF)
private val ColorMouth = Color(0xFFE94560)
private val ColorTongue = Color(0xFFFF6B8A)
private val ColorBlush = Color(0x4DE94560)
private val ColorEyebrow = Color(0xBF2D2D44)  // ~75% opaque

// Robot parts
private val ColorAntennaStroke = Color(0xFF4D4D80)
private val ColorAntennaGlow = Color(0xCC66AAFF)

// ─── Geometry Constants (relative to canvas size) ─────────────
private const val FACE_RADIUS_FRACTION = 0.38f
private const val FACE_CENTER_Y_FRACTION = 0.46f
private const val EYE_Y_FRACTION = 0.36f
private const val EYE_SPACING_FRACTION = 0.22f
private const val EYE_SOCKET_W_FRACTION = 0.20f
private const val EYE_SOCKET_H_FRACTION = 0.20f
private const val PUPIL_RADIUS_FRACTION = 0.07f
private const val PUPIL_MAX_OFFSET_X_FRACTION = 0.07f
private const val PUPIL_MAX_OFFSET_Y_FRACTION = 0.04f
private const val IRIS_RADIUS_FRACTION = 0.09f
private const val MOUTH_Y_FRACTION = 0.58f
private const val MOUTH_W_FRACTION = 0.16f
private const val EYEBROW_Y_OFFSET_FRACTION = 0.078f
private const val EYEBROW_LENGTH_FRACTION = 0.14f
private const val EYEBROW_THICKNESS = 3.5f

// Antenna
private const val ANTENNA_BASE_Y_FRACTION = 0.04f
private const val ANTENNA_HEIGHT_FRACTION = 0.10f
private const val ANTENNA_BALL_RADIUS_FRACTION = 0.025f
private const val ANTENNA_STICK_WIDTH = 3f

@Composable
fun RobotFaceScreen(
    state: RobotState,
    onTap: () -> Unit = {},
    onSettingsClick: () -> Unit = {},
    wakeWordEnabled: Boolean = false,
    onToggleWakeWord: () -> Unit = {}
) {
    val targetX by animateFloatAsState(
        targetValue = state.faceTargetX ?: 0.5f,
        animationSpec = tween(200, easing = FastOutSlowInEasing)
    )
    val targetY by animateFloatAsState(
        targetValue = state.faceTargetY ?: 0.5f,
        animationSpec = tween(200, easing = FastOutSlowInEasing)
    )

    val idleWander = remember { Animatable(0f) }
    val blinkProgress = remember { Animatable(0f) }
    val speakMouth = remember { Animatable(0f) }
    val thinkPhase = remember { Animatable(0f) }
    val listenPulse = remember { Animatable(0f) }

    LaunchedEffect(state.faceTargetX) {
        if (state.faceTargetX == null) {
            while (isActive) {
                idleWander.animateTo(
                    targetValue = Random.nextFloat() * 2f - 1f,
                    animationSpec = tween(2000 + Random.nextInt(1500), easing = FastOutSlowInEasing)
                )
            }
        }
    }

    LaunchedEffect(state.blinkTrigger) {
        if (state.blinkTrigger > 0L) {
            blinkProgress.snapTo(0f)
            blinkProgress.animateTo(1f, tween(80))
            delay(120)
            blinkProgress.animateTo(0f, tween(80))
        }
    }

    LaunchedEffect(state.isSpeaking) {
        if (state.isSpeaking) {
            while (isActive) {
                speakMouth.animateTo(1f, tween(180))  // ~5.5 Hz, easy on GPU
                speakMouth.animateTo(0.2f, tween(180))
            }
        } else {
            speakMouth.snapTo(0f)
        }
    }

    LaunchedEffect(state.mode) {
        if (state.mode == RobotMode.THINKING) {
            while (isActive) {
                thinkPhase.animateTo(1f, tween(1000, easing = FastOutSlowInEasing))
                thinkPhase.animateTo(-1f, tween(1000, easing = FastOutSlowInEasing))
            }
        } else {
            thinkPhase.snapTo(0f)
        }
    }

    LaunchedEffect(state.mode) {
        if (state.mode == RobotMode.LISTENING) {
            while (isActive) {
                listenPulse.animateTo(1f, tween(450))
                listenPulse.animateTo(0.2f, tween(450))
            }
        } else {
            listenPulse.snapTo(0f)
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(ColorBg)
    ) {
        Canvas(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer { alpha = 0.99f }  // isolate to own render layer, skip parent invalidation
                .pointerInput(Unit) {
                    detectTapGestures(onTap = { onTap() })
                }
        ) {
            val cx = size.width / 2f
            val cy = size.height * FACE_CENTER_Y_FRACTION
            val faceRadius = size.width * FACE_RADIUS_FRACTION

            // ── Face with radial gradient ──
            val faceCenter = Offset(cx, cy)
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(ColorFaceFillLight, ColorFaceFillMid),
                    center = Offset(cx, cy - faceRadius * 0.5f),
                    radius = faceRadius * 1.1f
                ),
                radius = faceRadius,
                center = faceCenter
            )
            drawCircle(
                color = ColorFaceBorder,
                radius = faceRadius,
                center = faceCenter,
                style = Stroke(width = 4f)
            )

            // ── Antenna ──
            drawAntenna(cx, cy, faceRadius, state.mode, listenPulse.value)

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

            val isThinking = state.mode == RobotMode.THINKING
            val (pupilDx, pupilDy) = if (isThinking) {
                (thinkPhase.value * maxPupilOffsetX * 0.3f) to (-maxPupilOffsetY * 0.9f)
            } else {
                computePupilOffset(
                    targetX, targetY, state.faceTargetX != null,
                    idleWander.value, maxPupilOffsetX, maxPupilOffsetY
                )
            }

            // ── Blush ──
            if (state.emotion == Emotion.HAPPY || state.emotion == Emotion.SHY) {
                drawBlush(leftEyeCx, eyeY, socketW)
                drawBlush(rightEyeCx, eyeY, socketW)
            }

            // ── Eyebrows ──
            val browEmotion = if (isThinking) Emotion.CURIOUS else state.emotion
            drawEyebrow(leftEyeCx, eyeY - eyebrowYOff, eyebrowHalfLen, browEmotion, left = true)
            drawEyebrow(rightEyeCx, eyeY - eyebrowYOff, eyebrowHalfLen, browEmotion, left = false)

            // ── Eyes ──
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

            // ── Mouth ──
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
                RobotMode.THINKING -> drawThinkingIndicator(cx, cy - faceRadius - 40f)
                else -> {}
            }

            // ── Status ring ──
            if (state.mode == RobotMode.THINKING || state.mode == RobotMode.SPEAKING) {
                val alpha = if (state.mode == RobotMode.THINKING) 0.4f else 0.9f
                val color = if (state.mode == RobotMode.THINKING)
                    Color(0xFF66AAFF).copy(alpha = alpha)
                else
                    ColorMouth.copy(alpha = alpha)
                drawCircle(
                    color = color,
                    radius = faceRadius + 6f,
                    center = Offset(cx, cy),
                    style = Stroke(width = 3f)
                )
            }

            // ── Face text below ──
            if (state.lastUserText != null && state.mode != RobotMode.IDLE) {
                drawContextBubble(cx, state)
            }
        }

            // ── Top overlay: ear (wake word) + gear (settings) ──
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 12.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.End,
            verticalAlignment = Alignment.CenterVertically
        ) {
            // Wake word toggle (ear icon)
            IconButton(onClick = onToggleWakeWord) {
                EarIcon(
                    active = wakeWordEnabled,
                    tint = if (wakeWordEnabled) Color(0xFF4488FF)
                        else Color.White.copy(alpha = 0.55f)
                )
            }

            Spacer(modifier = Modifier.width(2.dp))

            // Settings gear
            IconButton(onClick = onSettingsClick) {
                Icon(
                    imageVector = Icons.Filled.Settings,
                    contentDescription = "设置",
                    tint = Color.White.copy(alpha = 0.6f),
                    modifier = Modifier.size(44.dp)
                )
            }
        }

        // ── Status text below face ──
        val statusText = when (state.mode) {
            RobotMode.LISTENING -> "聆听中..."
            RobotMode.THINKING -> "思考中..."
            RobotMode.SPEAKING -> state.responseText ?: ""
            else -> ""
        }
        if (statusText.isNotEmpty()) {
            Text(
                text = statusText,
                color = Color.White.copy(alpha = 0.7f),
                maxLines = 2,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(horizontal = 40.dp)
                    .padding(bottom = 40.dp)
            )
        }
    }
}

/**
 * Ear icon using vector drawables — matches iOS SF Symbol "ear" / "ear.fill".
 */
@Composable
private fun EarIcon(active: Boolean, tint: Color) {
    Icon(
        painter = androidx.compose.ui.res.painterResource(
            id = if (active) com.rd.avatar.R.drawable.ic_ear_fill
                 else com.rd.avatar.R.drawable.ic_ear
        ),
        contentDescription = if (active) "关闭唤醒词" else "开启唤醒词",
        tint = tint,
        modifier = Modifier.size(44.dp)
    )
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

// ─── Antenna ───────────────────────────────────────────────────

private fun DrawScope.drawAntenna(
    faceCx: Float, faceCy: Float, faceRadius: Float,
    mode: RobotMode, pulse: Float
) {
    val baseY = faceCy - faceRadius + size.height * ANTENNA_BASE_Y_FRACTION
    val stickH = size.height * ANTENNA_HEIGHT_FRACTION
    val ballR = size.width * ANTENNA_BALL_RADIUS_FRACTION
    val tipY = baseY - stickH
    val ballCy = tipY - ballR

    val isListening = mode == RobotMode.LISTENING
    val ballColor = if (isListening) {
        val alpha = 0.4f + pulse * 0.6f   // blink between 0.4 and 1.0
        Color(0xFFFF3333).copy(alpha = alpha)
    } else {
        ColorAntennaGlow
    }

    // Stick
    drawLine(
        color = ColorAntennaStroke,
        start = Offset(faceCx, baseY),
        end = Offset(faceCx, tipY),
        strokeWidth = ANTENNA_STICK_WIDTH,
        cap = androidx.compose.ui.graphics.StrokeCap.Round
    )

    // Glow
    val glowR = ballR * 2f
    drawCircle(
        brush = Brush.radialGradient(
            colors = listOf(
                ballColor.copy(alpha = ballColor.alpha * 0.5f),
                ballColor.copy(alpha = 0f)
            ),
            center = Offset(faceCx, ballCy),
            radius = glowR
        ),
        radius = glowR,
        center = Offset(faceCx, ballCy)
    )

    // Ball
    drawCircle(
        color = ballColor,
        radius = ballR,
        center = Offset(faceCx, ballCy)
    )

    // Highlight
    val hlR = ballR * 0.3f
    drawCircle(
        color = Color.White.copy(alpha = 0.7f),
        radius = hlR * 0.4f,
        center = Offset(faceCx - hlR * 0.7f, ballCy - hlR * 1.2f)
    )
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
    val socketRect = androidx.compose.ui.geometry.Rect(socketTopLeft, socketSize)

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

    // Eye outline — before eyelid so lid covers it when blinking
    if (emotion != Emotion.HAPPY && lidScale < 0.98f) {
        drawOval(
            color = ColorFaceBorder,
            topLeft = socketTopLeft,
            size = socketSize,
            style = Stroke(width = 3f)
        )
    }

    // Eyelid — clipped to socket oval so it follows the eye contour
    if (lidScale > 0.01f) {
        val lidHeight = socketH * lidScale
        val lidTop = eyeY - socketH / 2f
        val ovalPath = Path().apply { addOval(socketRect) }
        clipPath(ovalPath) {
            drawRect(
                color = ColorFaceFillLight,
                topLeft = Offset(eyeCx - socketW / 2f - 8f, lidTop - 8f),
                size = Size(socketW + 16f, lidHeight + 8f)
            )
        }
    }
}

// ─── Eyebrow ──────────────────────────────────────────────────

private fun DrawScope.drawEyebrow(
    eyeCx: Float, browY: Float,
    halfLen: Float,
    emotion: Emotion,
    left: Boolean
) {
    val path = Path()
    val x0 = eyeCx - halfLen
    val x1 = eyeCx + halfLen
    val arch = halfLen * 0.35f

    when (emotion) {
        Emotion.HAPPY -> {
            path.moveTo(x0, browY)
            path.cubicTo(
                x0 + halfLen * 0.4f, browY - arch * 1.6f,
                x1 - halfLen * 0.4f, browY - arch * 1.6f,
                x1, browY
            )
        }
        Emotion.SAD -> {
            val sign = if (left) 1f else -1f
            val innerX = if (left) x1 else x0
            val outerX = if (left) x0 else x1
            path.moveTo(outerX, browY + halfLen * 0.45f)
            path.cubicTo(
                outerX + sign * halfLen * 0.6f, browY + halfLen * 0.2f,
                innerX - sign * halfLen * 0.6f, browY - halfLen * 0.05f,
                innerX, browY - halfLen * 0.15f
            )
        }
        Emotion.SURPRISED -> {
            val highArch = arch * 1.8f
            path.moveTo(x0, browY - highArch * 0.7f)
            path.cubicTo(
                x0 + halfLen * 0.3f, browY - highArch * 1.1f,
                x1 - halfLen * 0.3f, browY - highArch * 1.1f,
                x1, browY - highArch * 0.7f
            )
        }
        Emotion.CURIOUS -> {
            val raise = if (left) arch * 1.3f else 0f
            path.moveTo(x0, browY - raise)
            path.cubicTo(
                x0 + halfLen * 0.5f, browY - raise - arch * 0.5f,
                x1 - halfLen * 0.5f, browY - raise - arch * 0.1f,
                x1, browY - raise * 0.2f
            )
        }
        Emotion.SLEEPY -> {
            path.moveTo(x0, browY - arch * 0.2f)
            path.cubicTo(
                x0 + halfLen * 0.5f, browY + halfLen * 0.05f,
                x1 - halfLen * 0.5f, browY + halfLen * 0.15f,
                x1, browY + halfLen * 0.2f
            )
        }
        Emotion.SHY -> {
            path.moveTo(x0, browY - arch * 0.3f)
            path.cubicTo(
                x0 + halfLen * 0.4f, browY - arch * 1.0f,
                x1 - halfLen * 0.4f, browY - arch * 1.0f,
                x1, browY - arch * 0.3f
            )
        }
        else -> {
            // NEUTRAL: gentle natural arch
            path.moveTo(x0, browY)
            path.cubicTo(
                x0 + halfLen * 0.4f, browY - arch,
                x1 - halfLen * 0.4f, browY - arch,
                x1, browY
            )
        }
    }

    drawPath(
        path = path,
        color = ColorEyebrow,
        style = Stroke(
            width = EYEBROW_THICKNESS,
            cap = androidx.compose.ui.graphics.StrokeCap.Round,
            join = androidx.compose.ui.graphics.StrokeJoin.Round
        )
    )
}

// ─── Blush ────────────────────────────────────────────────────

private fun DrawScope.drawBlush(cx: Float, eyeY: Float, eyeW: Float) {
    val blushY = eyeY + eyeW * 0.9f
    drawCircle(
        color = ColorBlush,
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
    // ── Speaking: outlined oval, ry oscillates 80%↔100% ─────
    if (isSpeaking) {
        val rx = halfWidth * 0.7f          // constant horizontal radius
        val baseRy = halfWidth * 0.5f       // base vertical radius
        val scale = 0.75f + speakAmount * 0.25f  // 0.8 → 1.0
        val ry = baseRy * scale
        drawOval(
            color = ColorMouth,
            topLeft = Offset(cx - rx, mouthY - ry),
            size = Size(rx * 2f, ry * 2f),
            style = Stroke(width = 3.5f, cap = StrokeCap.Round)
        )
        // Tongue inside speaking mouth
        val tongueW = rx * 0.5f
        val tongueH = ry * 0.65f
        val tongueY = mouthY + ry * 0.55f
        drawTongue(cx, tongueY, tongueW, tongueH)
        return
    }

    // ── Closed mouth: thin curved line ─────────────────────────
    val path = Path()
    val bw: Float
    val cpY: Float

    when (emotion) {
        Emotion.HAPPY -> { bw = 1.2f; cpY = halfWidth * 0.9f }
        Emotion.SAD -> { bw = 0.7f; cpY = -halfWidth * 0.45f }
        Emotion.SURPRISED -> {
            val r = halfWidth * 0.35f
            drawOval(
                color = ColorMouth,
                topLeft = Offset(cx - r, mouthY - r * 0.7f),
                size = Size(r * 2f, r * 2f),
                style = Stroke(width = 3.5f)
            )
            // Tongue inside surprised mouth
            val tongueW = r * 0.45f
            val tongueH = r * 0.55f
            val tongueY = mouthY + r * 0.5f
            drawTongue(cx, tongueY, tongueW, tongueH)
            return
        }
        Emotion.CURIOUS -> {
            drawCircle(ColorMouth, halfWidth * 0.35f, Offset(cx, mouthY))
            return
        }
        Emotion.SLEEPY -> { bw = 0.5f; cpY = halfWidth * 0.3f }
        Emotion.SHY -> { bw = 0.45f; cpY = halfWidth * 0.15f }
        else -> { bw = 0.65f; cpY = halfWidth * 0.12f }
    }

    val x0 = cx - halfWidth * bw
    val x1 = cx + halfWidth * bw
    path.moveTo(x0, mouthY)
    path.quadraticBezierTo(cx, mouthY + cpY, x1, mouthY)

    drawPath(
        path = path,
        color = ColorMouth,
        style = Stroke(
            width = 3.5f,
            cap = androidx.compose.ui.graphics.StrokeCap.Round
        )
    )
}

// ─── Tongue ──────────────────────────────────────────────────

private fun DrawScope.drawTongue(
    cx: Float, baseY: Float,
    width: Float, height: Float
) {
    // Main tongue body: a soft rounded shape using an oval clipped to a path
    val tonguePath = Path().apply {
        // Rounded shape: wider at top, narrower at bottom
        moveTo(cx - width, baseY)
        cubicTo(
            cx - width, baseY - height * 0.8f,
            cx - width * 0.6f, baseY - height,
            cx, baseY - height
        )
        cubicTo(
            cx + width * 0.6f, baseY - height,
            cx + width, baseY - height * 0.8f,
            cx + width, baseY
        )
        // Slight indent at top center for cute tongue groove
        cubicTo(
            cx + width * 0.3f, baseY - height * 0.15f,
            cx - width * 0.3f, baseY - height * 0.15f,
            cx - width, baseY
        )
    }
    drawPath(tonguePath, ColorTongue)

    // Tongue highlight
    drawCircle(
        color = Color.White.copy(alpha = 0.35f),
        radius = width * 0.15f,
        center = Offset(cx - width * 0.1f, baseY - height * 0.6f)
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

private fun DrawScope.drawThinkingIndicator(cx: Float, y: Float) {
    val dotRadius = 5f
    val spacing = 14f
    for (i in -1..1) {
        drawCircle(
            color = ColorMouth.copy(alpha = 0.6f),
            radius = dotRadius,
            center = Offset(cx + i * spacing, y)
        )
    }
}

private fun DrawScope.drawContextBubble(cx: Float, state: RobotState) {
    val active = state.lastUserText != null
    if (active) {
        if (state.mode == RobotMode.THINKING || state.mode == RobotMode.SPEAKING) {
            val alpha = if (state.mode == RobotMode.THINKING) 0.4f else 0.9f
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
