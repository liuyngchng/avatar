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
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
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
private val ColorBg        = Color(0xFF1A1A2E)
private val ColorStickBody = Color(0xFFF0ECE6)       // warm white for body/limbs
private val ColorHeadFill  = Color(0xFFFAF8F5)       // slightly warmer head fill
private val ColorHeadStroke= Color(0xFFD0CCC6)       // subtle head outline
private val ColorEye       = Color(0xFF1A1A2E)       // dark navy eyes
private val ColorMouth     = Color(0xFFE94560)       // warm red mouth
private val ColorBlush     = Color(0x40E94560)       // translucent blush
private val ColorShadow    = Color(0x18000000)       // ground shadow
private val ColorAccent    = Color(0xFF66AAFF)       // mode accent

// ─── Stick Figure Geometry (relative to canvas) ──────────────
// The figure is positioned with feet at ~82% of canvas height
private const val FIGURE_HEIGHT_FRACTION = 0.52f   // total figure height / canvas height
private const val FEET_Y_FRACTION        = 0.82f   // where feet touch ground
private const val HEAD_RADIUS_FRACTION   = 0.085f  // head radius / canvas width
private const val BODY_LENGTH_FRACTION   = 0.17f   // neck→hip / canvas height
private const val UPPER_ARM_FRACTION     = 0.10f   // shoulder→elbow / canvas height
private const val FOREARM_FRACTION       = 0.09f   // elbow→hand / canvas height
private const val UPPER_LEG_FRACTION     = 0.13f   // hip→knee / canvas height
private const val LOWER_LEG_FRACTION     = 0.12f   // knee→foot / canvas height
private const val SHOULDER_W_FRACTION    = 0.06f   // shoulder half-width / canvas width
private const val HIP_W_FRACTION         = 0.04f   // hip half-width / canvas width

// Line weights
private const val BODY_STROKE    = 6f
private const val LIMB_STROKE    = 5f
private const val JOINT_RADIUS   = 5f    // hand/foot dot
private const val EYE_RADIUS_FRACTION  = 0.012f
private const val MOUTH_W_FRACTION     = 0.04f

// ─── Main Composable ─────────────────────────────────────────

@Composable
fun RobotFaceScreen(
    state: RobotState,
    onTap: () -> Unit = {},
    onSettingsClick: () -> Unit = {},
    wakeWordEnabled: Boolean = false,
    onToggleWakeWord: () -> Unit = {}
) {
    // ── Animation states ──
    val idleWander   = remember { Animatable(0f) }
    val blinkProgress = remember { Animatable(0f) }
    val speakMouth   = remember { Animatable(0f) }
    val thinkPhase   = remember { Animatable(0f) }
    val listenPulse  = remember { Animatable(0f) }
    val breatheScale = remember { Animatable(1f) }
    val anticPhase   = remember { Animatable(0f) }  // goofy antic animation

    // Idle: eyes wander (always, since no face tracking)
    LaunchedEffect(Unit) {
        while (isActive) {
            idleWander.animateTo(
                targetValue = Random.nextFloat() * 2f - 1f,
                animationSpec = tween(2000 + Random.nextInt(1500), easing = FastOutSlowInEasing)
            )
        }
    }

    // Breathing (in IDLE/LOOKING)
    LaunchedEffect(state.mode) {
        if (state.mode == RobotMode.IDLE) {
            while (isActive) {
                breatheScale.animateTo(1.03f, tween(1800, easing = FastOutSlowInEasing))
                breatheScale.animateTo(0.97f, tween(1800, easing = FastOutSlowInEasing))
            }
        } else {
            breatheScale.snapTo(1f)
        }
    }

    // Goofy antic animation (triggered by anticTrigger)
    LaunchedEffect(state.anticTrigger) {
        if (state.anticTrigger > 0L && state.mode == RobotMode.IDLE) {
            anticPhase.animateTo(1f, tween(400, easing = FastOutSlowInEasing))
            delay(800)
            anticPhase.animateTo(0f, tween(600, easing = FastOutSlowInEasing))
        }
    }

    // Blink
    LaunchedEffect(state.blinkTrigger) {
        if (state.blinkTrigger > 0L) {
            blinkProgress.snapTo(0f)
            blinkProgress.animateTo(1f, tween(80))
            delay(120)
            blinkProgress.animateTo(0f, tween(80))
        }
    }

    // Speaking mouth
    LaunchedEffect(state.isSpeaking) {
        if (state.isSpeaking) {
            while (isActive) {
                speakMouth.animateTo(1f, tween(160))
                speakMouth.animateTo(0.15f, tween(160))
            }
        } else {
            speakMouth.snapTo(0f)
        }
    }

    // Thinking
    LaunchedEffect(state.mode) {
        if (state.mode == RobotMode.THINKING) {
            while (isActive) {
                thinkPhase.animateTo(1f, tween(1200, easing = FastOutSlowInEasing))
                thinkPhase.animateTo(-1f, tween(1200, easing = FastOutSlowInEasing))
            }
        } else {
            thinkPhase.snapTo(0f)
        }
    }

    // Listening pulse
    LaunchedEffect(state.mode) {
        if (state.mode == RobotMode.LISTENING) {
            while (isActive) {
                listenPulse.animateTo(1f, tween(500))
                listenPulse.animateTo(0.3f, tween(500))
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
                .graphicsLayer { alpha = 0.99f }
                .pointerInput(Unit) {
                    detectTapGestures(onTap = { onTap() })
                }
        ) {
            val w = size.width
            val h = size.height
            val cx = w / 2f
            val figureH = h * FIGURE_HEIGHT_FRACTION
            val feetY = h * FEET_Y_FRACTION
            val headR = w * HEAD_RADIUS_FRACTION
            val bodyLen = h * BODY_LENGTH_FRACTION
            val shoulderHalfW = w * SHOULDER_W_FRACTION
            val hipHalfW = w * HIP_W_FRACTION
            val upperArmLen = h * UPPER_ARM_FRACTION
            val forearmLen = h * FOREARM_FRACTION
            val upperLegLen = h * UPPER_LEG_FRACTION
            val lowerLegLen = h * LOWER_LEG_FRACTION
            val eyeR = w * EYE_RADIUS_FRACTION
            val mouthHalfW = w * MOUTH_W_FRACTION
            val jointR = JOINT_RADIUS

            // ── Core figure origin ──
            val headCY = feetY - figureH + headR
            val headCenter = Offset(cx, headCY)
            val neckY = headCY + headR
            val hipY = neckY + bodyLen

            // ── Pose angles (in radians, 0 = straight down) ──
            val pose = computePose(
                mode = state.mode,
                emotion = state.emotion,
                speakAmount = speakMouth.value,
                thinkPhase = thinkPhase.value,
                listenPulse = listenPulse.value,
                breatheAmount = breatheScale.value
            )

            // ── Compute joint positions ──
            val neck = Offset(cx + pose.neckShiftX, neckY)
            val leftShoulder  = Offset(neck.x - shoulderHalfW, neck.y)
            val rightShoulder = Offset(neck.x + shoulderHalfW, neck.y)
            val hip = Offset(cx + pose.hipShiftX, hipY)
            val leftHip  = Offset(hip.x - hipHalfW, hip.y)
            val rightHip = Offset(hip.x + hipHalfW, hip.y)

            // Arms
            val leftElbow = leftShoulder + angleToOffset(pose.leftUpperArmAngle, upperArmLen)
            val leftHand  = leftElbow + angleToOffset(pose.leftForearmAngle, forearmLen)
            val rightElbow = rightShoulder + angleToOffset(pose.rightUpperArmAngle, upperArmLen)
            val rightHand  = rightElbow + angleToOffset(pose.rightForearmAngle, forearmLen)

            // Legs
            val leftKnee = leftHip + angleToOffset(pose.leftUpperLegAngle, upperLegLen)
            val leftFoot = leftKnee + angleToOffset(pose.leftLowerLegAngle, lowerLegLen)
            val rightKnee = rightHip + angleToOffset(pose.rightUpperLegAngle, upperLegLen)
            val rightFoot = rightKnee + angleToOffset(pose.rightLowerLegAngle, lowerLegLen)

            // ── Eye tracking (idle wander only) ──
            val isThinking = state.mode == RobotMode.THINKING
            val (pupilDx, pupilDy) = if (isThinking) {
                (thinkPhase.value * headR * 0.15f) to (-headR * 0.55f)
            } else {
                val angle = idleWander.value * PI.toFloat()
                (cos(angle) * headR * 0.08f) to (sin(angle * 1.7f) * headR * 0.06f)
            }

            // ═══════════════════════════════════════════════════════
            //  DRAW ORDER: back to front
            // ═══════════════════════════════════════════════════════

            // ── Ground shadow ──
            drawGroundShadow(cx, feetY)

            // ── Legs ──
            drawLimb(leftHip, leftKnee, leftFoot, jointR)
            drawLimb(rightHip, rightKnee, rightFoot, jointR)

            // ── Body ──
            drawLine(
                color = ColorStickBody,
                start = neck,
                end = hip,
                strokeWidth = BODY_STROKE,
                cap = StrokeCap.Round
            )

            // ── Arms ──
            drawLimb(leftShoulder, leftElbow, leftHand, jointR)
            drawLimb(rightShoulder, rightElbow, rightHand, jointR)

            // ── Head ──
            drawStickHead(
                center = headCenter + Offset(pose.headShiftX, pose.headShiftY),
                radius = headR,
                emotion = state.emotion
            )

            // ── Face ──
            drawStickFace(
                headCenter = headCenter + Offset(pose.headShiftX, pose.headShiftY),
                headRadius = headR,
                pupilDx = pupilDx,
                pupilDy = pupilDy,
                eyeRadius = eyeR,
                mouthHalfW = mouthHalfW,
                emotion = state.emotion,
                isSpeaking = state.isSpeaking,
                speakAmount = speakMouth.value,
                blinkAmount = blinkProgress.value
            )

            // ── Mode indicators ──
            when (state.mode) {
                RobotMode.LISTENING -> drawListenWaves(
                    leftHand.x - jointR, leftHand.y, listenPulse.value
                )
                RobotMode.THINKING -> drawThinkDots(
                    headCenter.x + pose.headShiftX,
                    headCenter.y + pose.headShiftY - headR - 20f,
                    thinkPhase.value
                )
                RobotMode.LOOKING -> drawLookingIndicator(
                    headCenter.x + pose.headShiftX,
                    headCenter.y + pose.headShiftY - headR
                )
                else -> {}
            }

            // ── Status ring (pulse when active) ──
            if (state.mode == RobotMode.THINKING || state.mode == RobotMode.SPEAKING) {
                val alpha = if (state.mode == RobotMode.THINKING) 0.35f else 0.8f
                val color = if (state.mode == RobotMode.THINKING) ColorAccent
                    else ColorMouth
                drawCircle(
                    color = color.copy(alpha = alpha),
                    radius = headR + 10f,
                    center = headCenter + Offset(pose.headShiftX, pose.headShiftY),
                    style = Stroke(width = 2.5f)
                )
            }

            // ── LOOKING ring ──
            if (state.mode == RobotMode.LOOKING) {
                drawCircle(
                    color = Color(0xFF66DD66).copy(alpha = 0.6f),
                    radius = headR + 10f,
                    center = headCenter + Offset(pose.headShiftX, pose.headShiftY),
                    style = Stroke(width = 2.5f)
                )
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
            IconButton(onClick = onToggleWakeWord) {
                EarIcon(
                    active = wakeWordEnabled,
                    tint = if (wakeWordEnabled) Color(0xFF4488FF)
                    else Color.White.copy(alpha = 0.55f)
                )
            }
            Spacer(modifier = Modifier.width(2.dp))
            IconButton(onClick = onSettingsClick) {
                Icon(
                    imageVector = Icons.Filled.Settings,
                    contentDescription = "设置",
                    tint = Color.White.copy(alpha = 0.6f),
                    modifier = Modifier.size(44.dp)
                )
            }
        }

        // ── Status text below figure ──
        val statusText = when (state.mode) {
            RobotMode.LISTENING -> "聆听中..."
            RobotMode.THINKING  -> "思考中..."
            RobotMode.SPEAKING  -> state.responseText ?: ""
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

// ═══════════════════════════════════════════════════════════════
//  POSE SYSTEM
// ═══════════════════════════════════════════════════════════════

/**
 * All angles in radians, 0 = straight down, positive = clockwise.
 */
private data class StickPose(
    val headTilt: Float = 0f,          // head tilt angle
    val headShiftX: Float = 0f,        // horizontal head offset
    val headShiftY: Float = 0f,        // vertical head offset
    val neckShiftX: Float = 0f,        // body lean
    val hipShiftX: Float = 0f,
    val leftUpperArmAngle: Float,      // from shoulder
    val leftForearmAngle: Float,
    val rightUpperArmAngle: Float,
    val rightForearmAngle: Float,
    val leftUpperLegAngle: Float,      // from hip
    val leftLowerLegAngle: Float,
    val rightUpperLegAngle: Float,
    val rightLowerLegAngle: Float,
)

/** IDLE: relaxed standing */
private fun idlePose(): StickPose = StickPose(
    leftUpperArmAngle  = Math.toRadians((-12.0)).toFloat(),
    leftForearmAngle   = Math.toRadians(8.0).toFloat(),
    rightUpperArmAngle = Math.toRadians(12.0).toFloat(),
    rightForearmAngle  = Math.toRadians((-8.0)).toFloat(),
    leftUpperLegAngle  = Math.toRadians((-3.0)).toFloat(),
    leftLowerLegAngle  = 0f,
    rightUpperLegAngle = Math.toRadians(3.0).toFloat(),
    rightLowerLegAngle = 0f,
)

/** LISTENING: lean forward, hand cupping ear */
private fun listeningPose(pulse: Float): StickPose {
    val lean = 4f + pulse * 4f  // lean varies with pulse
    return StickPose(
        headTilt          = Math.toRadians((-6.0 - pulse * 4.0)).toFloat(),
        headShiftX        = 0f,
        headShiftY        = 0f,
        neckShiftX        = lean * 1.5f,
        hipShiftX         = lean * 0.8f,
        leftUpperArmAngle = Math.toRadians((-90.0 - pulse * 15.0)).toFloat(),  // left arm up to ear
        leftForearmAngle  = Math.toRadians((-30.0)).toFloat(),
        rightUpperArmAngle = Math.toRadians((18.0)).toFloat(),
        rightForearmAngle  = Math.toRadians((-10.0)).toFloat(),
        leftUpperLegAngle  = Math.toRadians((-2.0)).toFloat(),
        leftLowerLegAngle  = 0f,
        rightUpperLegAngle = Math.toRadians((5.0)).toFloat(),
        rightLowerLegAngle = 0f,
    )
}

/** SPEAKING: gesturing arms */
private fun speakingPose(speakAmount: Float): StickPose {
    // Arms gesture more when speaking; right arm waves more
    val gestureAmp = 25f
    val rightAngle = sin(speakAmount * PI.toFloat() * 2f) * gestureAmp
    val leftAngle  = cos(speakAmount * PI.toFloat() * 2f) * gestureAmp * 0.6f
    return StickPose(
        headTilt = Math.toRadians((rightAngle * 0.15).toDouble()).toFloat(),
        headShiftX = 0f, headShiftY = 0f, neckShiftX = 0f, hipShiftX = 0f,
        leftUpperArmAngle  = Math.toRadians((-18.0 - leftAngle)).toFloat(),
        leftForearmAngle   = Math.toRadians((-20.0 - leftAngle * 0.5)).toFloat(),
        rightUpperArmAngle = Math.toRadians((18.0 + rightAngle)).toFloat(),
        rightForearmAngle  = Math.toRadians((25.0 + rightAngle * 0.6)).toFloat(),
        leftUpperLegAngle  = Math.toRadians((-2.0)).toFloat(),
        leftLowerLegAngle  = 0f,
        rightUpperLegAngle = Math.toRadians(2.0).toFloat(),
        rightLowerLegAngle = 0f,
    )
}

/** THINKING: hand on chin, looking up */
private fun thinkingPose(phase: Float): StickPose {
    return StickPose(
        headTilt  = Math.toRadians((-8.0 + phase * 4.0)).toFloat(),
        headShiftX = phase * 3f,
        headShiftY = -3f,
        neckShiftX = phase * 2f,
        hipShiftX  = phase * 1.5f,
        leftUpperArmAngle  = Math.toRadians(10.0).toFloat(),   // hanging
        leftForearmAngle   = Math.toRadians(5.0).toFloat(),
        rightUpperArmAngle = Math.toRadians((-70.0)).toFloat(), // bent up to chin
        rightForearmAngle  = Math.toRadians(60.0).toFloat(),   // hand under chin
        leftUpperLegAngle  = Math.toRadians((-2.0)).toFloat(),
        leftLowerLegAngle  = 0f,
        rightUpperLegAngle = Math.toRadians(2.0).toFloat(),
        rightLowerLegAngle = 0f,
    )
}

/** LOOKING: rear camera active, peering pose */
private fun lookingPose(): StickPose = StickPose(
    headTilt = 0f,
    headShiftX = 0f, headShiftY = -4f,
    neckShiftX = 6f, hipShiftX = 3f,     // lean forward slightly
    leftUpperArmAngle  = Math.toRadians((-10.0)).toFloat(),
    leftForearmAngle   = Math.toRadians(6.0).toFloat(),
    rightUpperArmAngle = Math.toRadians((-75.0)).toFloat(), // hand above eyes
    rightForearmAngle  = Math.toRadians((-30.0)).toFloat(), // visor pose
    leftUpperLegAngle  = Math.toRadians((-2.0)).toFloat(),
    leftLowerLegAngle  = 0f,
    rightUpperLegAngle = Math.toRadians(4.0).toFloat(),
    rightLowerLegAngle = 0f,
)

/** Emotion overlay: modifies the base pose */
private fun emotionModifier(emotion: Emotion): StickPose {
    return when (emotion) {
        Emotion.HAPPY -> StickPose(
            headTilt = Math.toRadians(5.0).toFloat(), headShiftX = 0f, headShiftY = -5f,
            neckShiftX = 0f, hipShiftX = 0f,
            leftUpperArmAngle  = Math.toRadians((-20.0)).toFloat(),
            leftForearmAngle   = Math.toRadians((-15.0)).toFloat(),
            rightUpperArmAngle = Math.toRadians(20.0).toFloat(),
            rightForearmAngle  = Math.toRadians(15.0).toFloat(),
            leftUpperLegAngle  = Math.toRadians((-5.0)).toFloat(),
            leftLowerLegAngle  = 0f,
            rightUpperLegAngle = Math.toRadians(5.0).toFloat(),
            rightLowerLegAngle = 0f,
        )
        Emotion.SAD -> StickPose(
            headTilt = Math.toRadians((-10.0)).toFloat(), headShiftX = 0f, headShiftY = 8f,
            neckShiftX = 0f, hipShiftX = 0f,
            leftUpperArmAngle  = Math.toRadians(5.0).toFloat(),
            leftForearmAngle   = Math.toRadians(10.0).toFloat(),
            rightUpperArmAngle = Math.toRadians((-5.0)).toFloat(),
            rightForearmAngle  = Math.toRadians((-10.0)).toFloat(),
            leftUpperLegAngle  = 0f, leftLowerLegAngle = 0f,
            rightUpperLegAngle = 0f, rightLowerLegAngle = 0f,
        )
        Emotion.SURPRISED -> StickPose(
            headTilt = 0f, headShiftX = 0f, headShiftY = -8f,
            neckShiftX = 0f, hipShiftX = 0f,
            leftUpperArmAngle  = Math.toRadians((-40.0)).toFloat(),
            leftForearmAngle   = Math.toRadians((-50.0)).toFloat(),
            rightUpperArmAngle = Math.toRadians(40.0).toFloat(),
            rightForearmAngle  = Math.toRadians(50.0).toFloat(),
            leftUpperLegAngle  = Math.toRadians((-6.0)).toFloat(),
            leftLowerLegAngle  = 0f,
            rightUpperLegAngle = Math.toRadians(6.0).toFloat(),
            rightLowerLegAngle = 0f,
        )
        Emotion.SLEEPY -> StickPose(
            headTilt = Math.toRadians((-5.0)).toFloat(), headShiftX = 0f, headShiftY = 4f,
            neckShiftX = 0f, hipShiftX = 0f,
            leftUpperArmAngle  = Math.toRadians(8.0).toFloat(),
            leftForearmAngle   = Math.toRadians(15.0).toFloat(),
            rightUpperArmAngle = Math.toRadians((-8.0)).toFloat(),
            rightForearmAngle  = Math.toRadians((-15.0)).toFloat(),
            leftUpperLegAngle  = 0f, leftLowerLegAngle = 0f,
            rightUpperLegAngle = 0f, rightLowerLegAngle = 0f,
        )
        Emotion.SHY -> StickPose(
            headTilt = Math.toRadians((-8.0)).toFloat(), headShiftX = 0f, headShiftY = 3f,
            neckShiftX = 0f, hipShiftX = 0f,
            leftUpperArmAngle  = Math.toRadians(5.0).toFloat(),
            leftForearmAngle   = Math.toRadians(25.0).toFloat(),   // hands together-ish
            rightUpperArmAngle = Math.toRadians((-5.0)).toFloat(),
            rightForearmAngle  = Math.toRadians((-25.0)).toFloat(),
            leftUpperLegAngle  = Math.toRadians(3.0).toFloat(),
            leftLowerLegAngle  = Math.toRadians((-3.0)).toFloat(),
            rightUpperLegAngle = Math.toRadians((-3.0)).toFloat(),
            rightLowerLegAngle = Math.toRadians(3.0).toFloat(),
        )
        Emotion.CURIOUS -> StickPose(
            headTilt = Math.toRadians(8.0).toFloat(), headShiftX = 0f, headShiftY = -3f,
            neckShiftX = 0f, hipShiftX = 0f,
            leftUpperArmAngle  = Math.toRadians((-8.0)).toFloat(),
            leftForearmAngle   = Math.toRadians(5.0).toFloat(),
            rightUpperArmAngle = Math.toRadians((-60.0)).toFloat(),  // hand near chin
            rightForearmAngle  = Math.toRadians(50.0).toFloat(),
            leftUpperLegAngle  = Math.toRadians((-2.0)).toFloat(),
            leftLowerLegAngle  = 0f,
            rightUpperLegAngle = Math.toRadians(2.0).toFloat(),
            rightLowerLegAngle = 0f,
        )
        Emotion.GOOFY -> StickPose(
            // Wacky pose: one arm up, head tilted, legs akimbo
            headTilt = Math.toRadians(15.0).toFloat(), headShiftX = 0f, headShiftY = -3f,
            neckShiftX = 0f, hipShiftX = 0f,
            leftUpperArmAngle  = Math.toRadians((-120.0)).toFloat(),  // arm straight up!
            leftForearmAngle   = Math.toRadians((-90.0)).toFloat(),   // bent over head
            rightUpperArmAngle = Math.toRadians(60.0).toFloat(),      // arm out to side
            rightForearmAngle  = Math.toRadians((-90.0)).toFloat(),   // bent up
            leftUpperLegAngle  = Math.toRadians((-15.0)).toFloat(),   // leg kicked out
            leftLowerLegAngle  = Math.toRadians(10.0).toFloat(),
            rightUpperLegAngle = Math.toRadians(15.0).toFloat(),      // other leg out
            rightLowerLegAngle = Math.toRadians((-10.0)).toFloat(),
        )
        else -> idlePose()  // NEUTRAL
    }
}

/** Blend two poses with weight [t] (0 = a, 1 = b) */
private fun blendPose(a: StickPose, b: StickPose, t: Float): StickPose {
    if (t <= 0f) return a
    if (t >= 1f) return b
    return StickPose(
        headTilt = a.headTilt + (b.headTilt - a.headTilt) * t,
        headShiftX = a.headShiftX + (b.headShiftX - a.headShiftX) * t,
        headShiftY = a.headShiftY + (b.headShiftY - a.headShiftY) * t,
        neckShiftX = a.neckShiftX + (b.neckShiftX - a.neckShiftX) * t,
        hipShiftX  = a.hipShiftX  + (b.hipShiftX  - a.hipShiftX)  * t,
        leftUpperArmAngle  = lerpAngle(a.leftUpperArmAngle, b.leftUpperArmAngle, t),
        leftForearmAngle   = lerpAngle(a.leftForearmAngle, b.leftForearmAngle, t),
        rightUpperArmAngle = lerpAngle(a.rightUpperArmAngle, b.rightUpperArmAngle, t),
        rightForearmAngle  = lerpAngle(a.rightForearmAngle, b.rightForearmAngle, t),
        leftUpperLegAngle  = lerpAngle(a.leftUpperLegAngle, b.leftUpperLegAngle, t),
        leftLowerLegAngle  = lerpAngle(a.leftLowerLegAngle, b.leftLowerLegAngle, t),
        rightUpperLegAngle = lerpAngle(a.rightUpperLegAngle, b.rightUpperLegAngle, t),
        rightLowerLegAngle = lerpAngle(a.rightLowerLegAngle, b.rightLowerLegAngle, t),
    )
}

private fun lerpAngle(a: Float, b: Float, t: Float): Float {
    // Shortest path around the circle
    var diff = b - a
    while (diff > PI.toFloat()) diff -= 2f * PI.toFloat()
    while (diff < -PI.toFloat()) diff += 2f * PI.toFloat()
    return a + diff * t
}

/**
 * Compute the final pose for the current state.
 */
private fun computePose(
    mode: RobotMode,
    emotion: Emotion,
    speakAmount: Float,
    thinkPhase: Float,
    listenPulse: Float,
    breatheAmount: Float
): StickPose {
    // Base pose from mode
    val modePose = when (mode) {
        RobotMode.IDLE      -> idlePose()
        RobotMode.LISTENING -> listeningPose(listenPulse)
        RobotMode.SPEAKING  -> speakingPose(speakAmount)
        RobotMode.THINKING  -> thinkingPose(thinkPhase)
        RobotMode.LOOKING   -> lookingPose()
    }

    // Blend with emotion modifier
    val emotionPose = emotionModifier(emotion)
    val emotionWeight = when (emotion) {
        Emotion.NEUTRAL   -> 0f
        Emotion.HAPPY     -> 0.55f
        Emotion.SAD       -> 0.7f
        Emotion.SURPRISED -> 0.85f
        Emotion.SLEEPY    -> 0.65f
        Emotion.SHY       -> 0.6f
        Emotion.CURIOUS   -> 0.4f
        Emotion.GOOFY     -> 0.9f   // strong goofy override
    }

    val result = blendPose(modePose, emotionPose, emotionWeight)

    // Apply breathing scale (IDLE only — no more WATCHING)
    if (mode == RobotMode.IDLE) {
        return result.copy(
            headShiftY = result.headShiftY + (1f - breatheAmount) * 8f
        )
    }
    return result
}

// ═══════════════════════════════════════════════════════════════
//  DRAWING HELPERS
// ═══════════════════════════════════════════════════════════════

/** Convert polar (angle from downward, length) to cartesian offset */
private fun angleToOffset(angleRad: Float, length: Float): Offset {
    return Offset(
        x = sin(angleRad) * length,
        y = cos(angleRad) * length
    )
}

/** Draw a two-segment limb (e.g. upper+lower arm, upper+lower leg) */
private fun DrawScope.drawLimb(
    joint1: Offset, joint2: Offset, joint3: Offset,
    endRadius: Float
) {
    // Segment 1
    drawLine(
        color = ColorStickBody,
        start = joint1,
        end = joint2,
        strokeWidth = LIMB_STROKE,
        cap = StrokeCap.Round
    )
    // Segment 2
    drawLine(
        color = ColorStickBody,
        start = joint2,
        end = joint3,
        strokeWidth = LIMB_STROKE,
        cap = StrokeCap.Round
    )
    // Joint dot at elbow/knee
    drawCircle(
        color = ColorStickBody,
        radius = endRadius * 0.6f,
        center = joint2
    )
    // End dot (hand/foot)
    drawCircle(
        color = ColorStickBody,
        radius = endRadius,
        center = joint3
    )
}

/** Draw the stick figure head (filled circle + subtle shading) */
private fun DrawScope.drawStickHead(
    center: Offset, radius: Float,
    emotion: Emotion
) {
    // Subtle radial gradient for depth
    drawCircle(
        brush = Brush.radialGradient(
            colors = listOf(ColorHeadFill, Color(0xFFE8E4DE)),
            center = Offset(center.x - radius * 0.2f, center.y - radius * 0.35f),
            radius = radius * 1.1f
        ),
        radius = radius,
        center = center
    )
    // Outline
    drawCircle(
        color = ColorHeadStroke,
        radius = radius,
        center = center,
        style = Stroke(width = 2.5f)
    )

    // Blush for happy/shy
    if (emotion == Emotion.HAPPY || emotion == Emotion.SHY) {
        val blushR = radius * 0.22f
        val blushY = center.y + radius * 0.25f
        val blushXOff = radius * 0.55f
        drawCircle(color = ColorBlush, radius = blushR, center = Offset(center.x - blushXOff, blushY))
        drawCircle(color = ColorBlush, radius = blushR, center = Offset(center.x + blushXOff, blushY))
    }
}

/** Draw eyes + mouth on the stick figure head */
private fun DrawScope.drawStickFace(
    headCenter: Offset,
    headRadius: Float,
    pupilDx: Float,
    pupilDy: Float,
    eyeRadius: Float,
    mouthHalfW: Float,
    emotion: Emotion,
    isSpeaking: Boolean,
    speakAmount: Float,
    blinkAmount: Float
) {
    // Eye positions (relative to head center)
    val eyeY = headCenter.y - headRadius * 0.15f
    val eyeXOff = headRadius * 0.38f
    val leftEyeCenter  = Offset(headCenter.x - eyeXOff, eyeY)
    val rightEyeCenter = Offset(headCenter.x + eyeXOff, eyeY)

    // ── Eyes ──
    val lidScale = when (emotion) {
        Emotion.SLEEPY -> 0.4f + blinkAmount * 0.6f
        Emotion.SHY    -> 0.35f + blinkAmount * 0.65f
        Emotion.HAPPY  -> 0.2f + blinkAmount * 0.8f
        else -> blinkAmount
    }

    if (lidScale < 0.95f) {
        drawStickEye(leftEyeCenter, pupilDx, pupilDy, eyeRadius, lidScale, emotion)
        drawStickEye(rightEyeCenter, pupilDx, pupilDy, eyeRadius, lidScale, emotion)
    }

    // ── Eyebrows (simple curved lines) ──
    if (emotion != Emotion.NEUTRAL) {
        val browY = eyeY - eyeRadius * 2.8f
        val browLen = eyeRadius * 2.5f
        drawStickEyebrow(leftEyeCenter.x, browY, browLen, emotion, left = true)
        drawStickEyebrow(rightEyeCenter.x, browY, browLen, emotion, left = false)
    }

    // ── Mouth ──
    val mouthY = headCenter.y + headRadius * 0.35f
    drawStickMouth(
        cx = headCenter.x, mouthY = mouthY,
        halfWidth = mouthHalfW,
        emotion = emotion,
        isSpeaking = isSpeaking,
        speakAmount = speakAmount
    )
}

/** Draw a single stick-figure eye */
private fun DrawScope.drawStickEye(
    center: Offset, pupilDx: Float, pupilDy: Float,
    radius: Float, lidScale: Float, emotion: Emotion
) {
    val pupilCenter = Offset(center.x + pupilDx, center.y + pupilDy)

    // Eye shape varies by emotion
    when (emotion) {
        Emotion.SURPRISED -> {
            // Wide open circle
            drawCircle(color = ColorEye, radius = radius * 1.6f, center = pupilCenter)
            // Small highlight
            drawCircle(
                color = Color.White,
                radius = radius * 0.3f,
                center = Offset(pupilCenter.x - radius * 0.3f, pupilCenter.y - radius * 0.4f)
            )
        }
        Emotion.HAPPY -> {
            // Happy: upward arc (drawn as a thick short line)
            val arcPath = Path().apply {
                moveTo(pupilCenter.x - radius, pupilCenter.y + radius * 0.3f)
                quadraticBezierTo(
                    pupilCenter.x, pupilCenter.y - radius * 1.3f,
                    pupilCenter.x + radius, pupilCenter.y + radius * 0.3f
                )
            }
            drawPath(arcPath, ColorEye, style = Stroke(width = 2.5f, cap = StrokeCap.Round))
        }
        Emotion.SLEEPY -> {
            // Heavy eyelid: horizontal line
            drawLine(
                color = ColorEye,
                start = Offset(pupilCenter.x - radius * 1.3f, pupilCenter.y),
                end = Offset(pupilCenter.x + radius * 1.3f, pupilCenter.y),
                strokeWidth = 2.5f,
                cap = StrokeCap.Round
            )
        }
        Emotion.GOOFY -> {
            // Derp eyes: different sizes + one looking elsewhere
            // Big circle + tiny pupil
            drawCircle(color = ColorEye, radius = radius * 1.5f, center = pupilCenter)
            // Tiny off-center pupil
            drawCircle(
                color = Color.White,
                radius = radius * 0.4f,
                center = Offset(pupilCenter.x + radius * 0.6f, pupilCenter.y - radius * 0.3f)
            )
            drawCircle(
                color = ColorEye,
                radius = radius * 0.25f,
                center = Offset(pupilCenter.x + radius * 0.55f, pupilCenter.y - radius * 0.3f)
            )
        }
        else -> {
            // Normal: filled circle
            drawCircle(color = ColorEye, radius = radius, center = pupilCenter)
            // Tiny highlight
            drawCircle(
                color = Color.White,
                radius = radius * 0.25f,
                center = Offset(pupilCenter.x - radius * 0.25f, pupilCenter.y - radius * 0.35f)
            )
        }
    }

    // Eyelid overlay
    if (lidScale > 0.01f) {
        val lidH = radius * 3f * lidScale
        drawRect(
            color = ColorHeadFill,
            topLeft = Offset(center.x - radius * 1.8f, center.y - radius * 2.2f),
            size = Size(radius * 3.6f, lidH + radius * 0.5f)
        )
    }
}

/** Draw a stick-figure eyebrow */
private fun DrawScope.drawStickEyebrow(
    eyeCx: Float, browY: Float, halfLen: Float,
    emotion: Emotion, left: Boolean
) {
    val path = Path()
    val x0 = eyeCx - halfLen
    val x1 = eyeCx + halfLen
    val arch = halfLen * 0.4f

    when (emotion) {
        Emotion.HAPPY -> {
            path.moveTo(x0, browY)
            path.quadraticBezierTo(eyeCx, browY - arch * 1.5f, x1, browY)
        }
        Emotion.SAD -> {
            val sign = if (left) 1f else -1f
            path.moveTo(x0, browY + halfLen * 0.3f)
            path.quadraticBezierTo(
                eyeCx, browY - halfLen * 0.1f * sign,
                x1, browY - halfLen * 0.1f
            )
        }
        Emotion.SURPRISED -> {
            path.moveTo(x0, browY - arch)
            path.quadraticBezierTo(eyeCx, browY - arch * 2.2f, x1, browY - arch)
        }
        Emotion.CURIOUS -> {
            val raise = if (left) arch * 1.5f else 0f
            path.moveTo(x0, browY - raise)
            path.quadraticBezierTo(eyeCx, browY - raise - arch * 0.5f, x1, browY)
        }
        Emotion.SLEEPY -> {
            path.moveTo(x0, browY + halfLen * 0.15f)
            path.quadraticBezierTo(eyeCx, browY + halfLen * 0.25f, x1, browY + halfLen * 0.15f)
        }
        Emotion.SHY -> {
            path.moveTo(x0, browY - arch * 0.3f)
            path.quadraticBezierTo(eyeCx, browY - arch * 1.2f, x1, browY - arch * 0.3f)
        }
        Emotion.GOOFY -> {
            // One eyebrow way up, the other scrunched
            if (left) {
                path.moveTo(x0, browY - arch * 2f)
                path.quadraticBezierTo(eyeCx, browY - arch * 2.5f, x1, browY - arch * 1.5f)
            } else {
                path.moveTo(x0, browY + arch * 0.5f)
                path.quadraticBezierTo(eyeCx, browY - arch * 0.3f, x1, browY + arch * 0.8f)
            }
        }
        else -> {}
    }

    if (!path.isEmpty) {
        drawPath(
            path = path,
            color = ColorEye.copy(alpha = 0.7f),
            style = Stroke(width = 2.5f, cap = StrokeCap.Round)
        )
    }
}

/** Draw stick figure mouth */
private fun DrawScope.drawStickMouth(
    cx: Float, mouthY: Float, halfWidth: Float,
    emotion: Emotion, isSpeaking: Boolean, speakAmount: Float
) {
    // ── Speaking: animated oval ──
    if (isSpeaking) {
        val rx = halfWidth * 0.8f
        val baseRy = halfWidth * 0.55f
        val scale = 0.7f + speakAmount * 0.3f
        val ry = baseRy * scale
        drawOval(
            color = ColorMouth,
            topLeft = Offset(cx - rx, mouthY - ry),
            size = Size(rx * 2f, ry * 2f),
            style = Stroke(width = 3f, cap = StrokeCap.Round)
        )
        // Small tongue
        if (speakAmount > 0.5f) {
            val tongueW = rx * 0.35f
            val tongueH = ry * 0.5f
            drawOval(
                color = Color(0xFFFF6B8A),
                topLeft = Offset(cx - tongueW, mouthY + ry * 0.1f),
                size = Size(tongueW * 2f, tongueH * 2f)
            )
        }
        return
    }

    // ── Emotion-based closed mouth ──
    val path = Path()
    when (emotion) {
        Emotion.HAPPY -> {
            path.moveTo(cx - halfWidth, mouthY)
            path.quadraticBezierTo(cx, mouthY + halfWidth * 0.8f, cx + halfWidth, mouthY)
        }
        Emotion.SAD -> {
            path.moveTo(cx - halfWidth * 0.7f, mouthY)
            path.quadraticBezierTo(cx, mouthY - halfWidth * 0.4f, cx + halfWidth * 0.7f, mouthY)
        }
        Emotion.SURPRISED -> {
            val r = halfWidth * 0.45f
            drawOval(
                color = ColorMouth,
                topLeft = Offset(cx - r, mouthY - r * 0.3f),
                size = Size(r * 2f, r * 1.6f),
                style = Stroke(width = 2.5f, cap = StrokeCap.Round)
            )
            return
        }
        Emotion.CURIOUS -> {
            // Small "o" shape
            drawCircle(ColorMouth, halfWidth * 0.35f, Offset(cx, mouthY))
            return
        }
        Emotion.SLEEPY -> {
            path.moveTo(cx - halfWidth * 0.5f, mouthY)
            path.quadraticBezierTo(cx, mouthY + halfWidth * 0.2f, cx + halfWidth * 0.5f, mouthY)
        }
        Emotion.SHY -> {
            // Tiny wavy smile
            path.moveTo(cx - halfWidth * 0.45f, mouthY)
            path.quadraticBezierTo(cx, mouthY + halfWidth * 0.15f, cx + halfWidth * 0.45f, mouthY)
        }
        Emotion.GOOFY -> {
            // Tongue out to the side! (≧▽≦)
            val tonguePath = Path().apply {
                moveTo(cx + halfWidth * 0.1f, mouthY)
                quadraticBezierTo(
                    cx + halfWidth * 0.5f, mouthY + halfWidth * 1.0f,
                    cx + halfWidth * 0.8f, mouthY + halfWidth * 0.6f
                )
                quadraticBezierTo(
                    cx + halfWidth * 0.6f, mouthY + halfWidth * 0.2f,
                    cx - halfWidth * 0.3f, mouthY
                )
            }
            drawPath(tonguePath, Color(0xFFFF6B8A))  // pink tongue
            // Mouth line
            drawPath(
                Path().apply {
                    moveTo(cx - halfWidth * 0.3f, mouthY)
                    quadraticBezierTo(cx, mouthY + halfWidth * 0.3f, cx + halfWidth * 0.1f, mouthY)
                },
                color = ColorMouth,
                style = Stroke(width = 3f, cap = StrokeCap.Round)
            )
            return
        }
        else -> {
            // Neutral: subtle straight/slight curve
            path.moveTo(cx - halfWidth * 0.6f, mouthY)
            path.quadraticBezierTo(cx, mouthY + halfWidth * 0.08f, cx + halfWidth * 0.6f, mouthY)
        }
    }

    drawPath(
        path = path,
        color = ColorMouth,
        style = Stroke(width = 3f, cap = StrokeCap.Round)
    )
}

/** Ground shadow ellipse under the figure */
private fun DrawScope.drawGroundShadow(cx: Float, feetY: Float) {
    val shadowW = 50f
    val shadowH = 8f
    drawOval(
        color = ColorShadow,
        topLeft = Offset(cx - shadowW / 2f, feetY - shadowH / 2f),
        size = Size(shadowW, shadowH)
    )
}

/** Listening: sound waves near the ear */
private fun DrawScope.drawListenWaves(x: Float, y: Float, pulse: Float) {
    for (i in 0..2) {
        val r = 12f + i * 8f + pulse * 6f
        val alpha = (1f - i * 0.3f) * (0.3f + pulse * 0.7f)
        drawCircle(
            color = ColorAccent.copy(alpha = alpha),
            radius = r,
            center = Offset(x, y - 10f),
            style = Stroke(width = 2f)
        )
    }
}

/** Thinking: animated dots above head */
private fun DrawScope.drawThinkDots(cx: Float, y: Float, phase: Float) {
    for (i in 0..2) {
        val dotY = y - i * 16f + sin((phase + i * 0.5f) * PI.toFloat() * 2f) * 5f
        val alpha = 0.4f + (1f - i * 0.25f) * 0.4f
        drawCircle(
            color = ColorAccent.copy(alpha = alpha),
            radius = 4.5f - i * 0.8f,
            center = Offset(cx + 5f, dotY)
        )
    }
}

/** LOOKING: camera indicator — a small camera-like icon above head */
private fun DrawScope.drawLookingIndicator(cx: Float, y: Float) {
    // Camera body
    val bodyW = 14f
    val bodyH = 10f
    drawRoundRect(
        color = Color(0xFF66DD66).copy(alpha = 0.8f),
        topLeft = Offset(cx - bodyW / 2f, y - bodyH),
        size = Size(bodyW, bodyH),
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(2f, 2f)
    )
    // Lens
    drawCircle(
        color = Color.White.copy(alpha = 0.9f),
        radius = 3.5f,
        center = Offset(cx, y - bodyH / 2f)
    )
    // Flash
    drawCircle(
        color = Color(0xFFFFDD44).copy(alpha = 0.6f),
        radius = 2f,
        center = Offset(cx + bodyW / 2f - 2f, y - bodyH + 2f)
    )
}

// ─── Ear Icon ──────────────────────────────────────────────────

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
