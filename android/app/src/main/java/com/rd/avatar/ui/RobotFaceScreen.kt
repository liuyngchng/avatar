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
private val ColorStickBody = Color(0xFFF2CC3D)       // emoji yellow body/limbs
private val ColorHeadFill  = Color(0xFFFFE066)       // light yellow head
private val ColorHeadStroke= Color(0xFFDDB800)       // golden head outline
private val ColorEye       = Color(0xFF333333)       // soft charcoal eyes
private val ColorMouth     = Color(0xFF444444)       // emoji dark mouth
private val ColorBlush     = Color(0x40CC3333)       // translucent blush on yellow
private val ColorShadow    = Color(0x18000000)       // ground shadow
private val ColorAccent    = Color(0xFF66AAFF)       // mode accent

// ─── Stick Figure Geometry (relative to canvas) ──────────────
// The figure is positioned with feet at ~82% of canvas height
private const val FIGURE_HEIGHT_FRACTION = 0.52f   // total figure height / canvas height
private const val FEET_Y_FRACTION        = 0.82f   // where feet touch ground
private const val HEAD_RADIUS_FRACTION   = 0.085f  // head radius / canvas width
private const val BODY_LENGTH_FRACTION   = 0.19f   // neck→hip / canvas height (tuned so legs reach ground)
private const val UPPER_ARM_FRACTION     = 0.10f   // shoulder→elbow / canvas height
private const val FOREARM_FRACTION       = 0.09f   // elbow→hand / canvas height
private const val UPPER_LEG_FRACTION     = 0.13f   // hip→knee / canvas height
private const val LOWER_LEG_FRACTION     = 0.12f   // knee→foot / canvas height
private const val SHOULDER_W_FRACTION    = 0.06f   // shoulder half-width / canvas width
private const val HIP_W_FRACTION         = 0.04f   // hip half-width / canvas width

// Line weights
private const val BODY_STROKE    = 6f
private const val LIMB_STROKE    = 5f
private const val JOINT_RADIUS   = LIMB_STROKE * 0.8f   // hand/foot end cap
private const val EYE_RADIUS_FRACTION  = 0.012f
private const val MOUTH_W_FRACTION     = 0.04f

// ─── Walk direction ─────────────────────────────────────────
private enum class WalkType { NONE, LEFT, RIGHT, AWAY, TOWARD }

// ─── Main Composable ─────────────────────────────────────────

@Composable
fun RobotFaceScreen(
    state: RobotState,
    onTap: () -> Unit = {},
    onSettingsClick: () -> Unit = {},
    wakeWordEnabled: Boolean = false,
    onToggleWakeWord: () -> Unit = {},
    enginesReady: Boolean = true
) {
    // ── Animation states ──
    val idleWander   = remember { Animatable(0f) }
    val blinkProgress = remember { Animatable(0f) }
    val speakMouth   = remember { Animatable(0f) }
    val thinkPhase   = remember { Animatable(0f) }
    val listenPulse  = remember { Animatable(0f) }
    val breatheScale = remember { Animatable(1f) }
    val anticPhase   = remember { Animatable(0f) }  // goofy antic animation
    val jumpPhase    = remember { Animatable(0f) }  // jump animation 0→1
    val walkPhase    = remember { Animatable(0f) }  // walk progress 0→1
    var walkType     by remember { mutableStateOf(WalkType.NONE) }

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
            anticPhase.animateTo(1f, tween(800, easing = FastOutSlowInEasing))
            delay(1600)
            anticPhase.animateTo(0f, tween(1200, easing = FastOutSlowInEasing))
        }
    }

    // Jump animation (triggered ~20% of antics when idle)
    LaunchedEffect(state.anticTrigger) {
        if (state.anticTrigger > 0L && state.anticTrigger % 5L == 4L
            && state.mode == RobotMode.IDLE) {
            // Phase 1: crouch (0 → 0.25) — anticipation
            jumpPhase.snapTo(0f)
            jumpPhase.animateTo(0.25f, tween(400, easing = FastOutSlowInEasing))
            // Phase 2: launch up (0.25 → 0.6) — fast!
            jumpPhase.animateTo(0.6f, tween(500, easing = LinearEasing))
            // Phase 3: hold apex briefly
            delay(200)
            // Phase 4: fall + land (0.6 → 1.0) — gravity
            jumpPhase.animateTo(1f, tween(600, easing = FastOutSlowInEasing))
            // Reset
            jumpPhase.snapTo(0f)
        }
    }

    // Walk animation (triggered by specific antic values when idle)
    LaunchedEffect(state.anticTrigger) {
        if (state.anticTrigger > 0L && state.mode == RobotMode.IDLE) {
            // Don't walk if this trigger already handles jump/squat/lie
            val isJump  = state.anticTrigger % 5L == 4L
            val isSquat = state.anticTrigger % 7L == 3L
            val isLie   = state.anticTrigger > 3 && state.anticTrigger % 13L == 7L
            if (!isJump && !isSquat && !isLie) {
                when {
                    state.anticTrigger % 9L == 2L -> {
                        walkType = WalkType.LEFT
                        walkPhase.snapTo(0f)
                        walkPhase.animateTo(1f, tween(4000, easing = LinearEasing))
                        walkType = WalkType.NONE
                    }
                    state.anticTrigger % 9L == 5L -> {
                        walkType = WalkType.RIGHT
                        walkPhase.snapTo(0f)
                        walkPhase.animateTo(1f, tween(4000, easing = LinearEasing))
                        walkType = WalkType.NONE
                    }
                    state.anticTrigger % 11L == 3L -> {
                        walkType = WalkType.AWAY
                        walkPhase.snapTo(0f)
                        walkPhase.animateTo(1f, tween(5000, easing = FastOutSlowInEasing))
                        walkType = WalkType.NONE
                    }
                    state.anticTrigger % 11L == 8L -> {
                        walkType = WalkType.TOWARD
                        walkPhase.snapTo(0f)
                        walkPhase.animateTo(1f, tween(5000, easing = FastOutSlowInEasing))
                        walkType = WalkType.NONE
                    }
                }
            }
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

            // ── Pose angles (in radians, 0 = straight down) ──
            val pose = computePose(
                mode = state.mode,
                emotion = state.emotion,
                speakAmount = speakMouth.value,
                thinkPhase = thinkPhase.value,
                listenPulse = listenPulse.value,
                breatheAmount = breatheScale.value,
                anticTrigger = state.anticTrigger,
                jumpPhase = jumpPhase.value,
                enginesReady = enginesReady,
                walkType = walkType,
                walkPhase = walkPhase.value
            )

            val headCenter = Offset(cx, headCY)
            val neckY = headCY + headR
            // Body length compressed by bodyScale (for squatting)
            val effectiveHipY = neckY + bodyLen * (1f - pose.bodyScale)

            // ═══════════════════════════════════════════════════════
            //  GROUND — drawn BEFORE any figure transforms so it
            //  stays fixed regardless of jump / rotation / etc.
            // ═══════════════════════════════════════════════════════
            drawGroundLine(cx, feetY, w)
            drawGroundShadow(cx, feetY)

            // ── Auto-zoom: if rotated figure extends beyond canvas, scale down ──
            val lieScale = if (pose.figureRotation != 0f) {
                val absAngleRad = abs(pose.figureRotation) * PI.toFloat() / 180f
                val horizontalReach = sin(absAngleRad) * figureH + headR * 2.5f
                val availableW = w / 2f - 20f  // margin from edge
                if (horizontalReach > availableW) (availableW / horizontalReach).coerceIn(0.25f, 1f) else 1f
            } else 1f
            if (lieScale < 1f) {
                drawContext.transform.scale(lieScale, lieScale, Offset(cx, feetY))
            }

            // ── Whole-body rotation (for lying down) ──
            // Pivot around feet so the body rests on the ground after rotation.
            if (pose.figureRotation != 0f) {
                drawContext.transform.rotate(
                    pose.figureRotation,
                    Offset(cx, feetY)
                )
            }

            // ── Jump vertical offset (parabolic arc) ──
            val jumpDY = if (jumpPhase.value > 0.01f) {
                jumpOffsetY(jumpPhase.value, figureH)
            } else 0f
            if (jumpDY != 0f) {
                drawContext.transform.translate(0f, jumpDY)
            }

            // ── Walk transforms ──
            when (walkType) {
                WalkType.LEFT -> {
                    // Walk left: wrap around screen edges (exit left → appear right)
                    val cycleW = w
                    val rawOffset = -walkPhase.value * cycleW
                    val wrapped = wrapMod(rawOffset + cycleW / 2f, cycleW) - cycleW / 2f
                    drawContext.transform.translate(wrapped, 0f)
                }
                WalkType.RIGHT -> {
                    // Walk right: wrap around screen edges (exit right → appear left)
                    val cycleW = w
                    val rawOffset = walkPhase.value * cycleW
                    val wrapped = wrapMod(rawOffset + cycleW / 2f, cycleW) - cycleW / 2f
                    drawContext.transform.translate(wrapped, 0f)
                }
                WalkType.AWAY -> {
                    // Walk into depth: scale down + rise toward horizon (perspective)
                    val scale = 1f - walkPhase.value * 0.75f   // 1 → 0.25
                    val rise = walkPhase.value * figureH * 0.3f // move up as they recede
                    drawContext.transform.translate(cx, feetY)
                    drawContext.transform.scale(scale, scale)
                    drawContext.transform.translate(-cx, -feetY + rise)
                }
                WalkType.TOWARD -> {
                    // Walk out of depth: scale up + descend (perspective)
                    val scale = 0.25f + walkPhase.value * 0.75f // 0.25 → 1
                    val drop = (1f - walkPhase.value) * figureH * 0.3f
                    drawContext.transform.translate(cx, feetY)
                    drawContext.transform.scale(scale, scale)
                    drawContext.transform.translate(-cx, -feetY + drop)
                }
                WalkType.NONE -> { /* no walk transform */ }
            }

            // ── Compute joint positions ──
            val neck = Offset(cx + pose.neckShiftX, neckY)
            val leftShoulder  = Offset(neck.x - shoulderHalfW, neck.y)
            val rightShoulder = Offset(neck.x + shoulderHalfW, neck.y)
            val hip = Offset(cx + pose.hipShiftX, effectiveHipY + pose.hipShiftY)
            val leftHip  = Offset(hip.x - hipHalfW, hip.y)
            val rightHip = Offset(hip.x + hipHalfW, hip.y)

            // ── Start with FK angles from pose ──
            var laUA = pose.leftUpperArmAngle
            var laFA = pose.leftForearmAngle
            var raUA = pose.rightUpperArmAngle
            var raFA = pose.rightForearmAngle
            var llUA = pose.leftUpperLegAngle
            var llLA = pose.leftLowerLegAngle
            var rlUA = pose.rightUpperLegAngle
            var rlLA = pose.rightLowerLegAngle

            // ── IK overrides: precise hand/foot placement per mode ──
            val headForIK = headCenter + Offset(pose.headShiftX, pose.headShiftY)

            when (state.mode) {
                RobotMode.THINKING -> {
                    // Right hand IK → chin
                    val chin = Offset(headForIK.x + headR * 0.15f + thinkPhase.value * 4f,
                                      headForIK.y + headR * 0.6f)
                    solve2BoneIK(rightShoulder, upperArmLen, forearmLen, chin, bendCCW = false)?.let {
                        raUA = it.angle1; raFA = it.angle2
                    }
                }
                RobotMode.LISTENING -> {
                    // Left hand IK → near "ear"
                    val ear = Offset(headForIK.x - headR * 0.85f,
                                     headForIK.y - headR * 0.25f + listenPulse.value * 4f)
                    solve2BoneIK(leftShoulder, upperArmLen, forearmLen, ear, bendCCW = true)?.let {
                        laUA = it.angle1; laFA = it.angle2
                    }
                }
                else -> { /* FK only */ }
            }

            // ── Waking up: both hands IK → eyes (rub eyes) ──
            if (!enginesReady) {
                val leftEyeTarget = Offset(headForIK.x - headR * 0.5f, headForIK.y - headR * 0.05f)
                solve2BoneIK(leftShoulder, upperArmLen, forearmLen, leftEyeTarget, bendCCW = true)?.let {
                    laUA = it.angle1; laFA = it.angle2
                }
                val rightEyeTarget = Offset(headForIK.x + headR * 0.5f, headForIK.y - headR * 0.05f)
                solve2BoneIK(rightShoulder, upperArmLen, forearmLen, rightEyeTarget, bendCCW = false)?.let {
                    raUA = it.angle1; raFA = it.angle2
                }
            }

            // ── IK for legs: lock feet on ground (all standing poses) ──
            // Skip during jumps (feet leave ground) and lying (figure rotated)
            val isJumping = jumpPhase.value > 0.01f
            val isLying = pose.figureRotation != 0f
            if (!isJumping && !isLying) {
                val isSquatting = state.mode == RobotMode.IDLE &&
                    state.anticTrigger > 0 && state.anticTrigger % 7L == 3L
                // Wider stance for squatting, narrow for normal standing
                val footSpread = if (isSquatting) 22f else 6f
                solve2BoneIK(leftHip, upperLegLen, lowerLegLen,
                    Offset(leftHip.x - footSpread, feetY), bendCCW = true)?.let {
                    llUA = it.angle1; llLA = it.angle2
                }
                solve2BoneIK(rightHip, upperLegLen, lowerLegLen,
                    Offset(rightHip.x + footSpread, feetY), bendCCW = false)?.let {
                    rlUA = it.angle1; rlLA = it.angle2
                }
            }

            // ── Final limb positions (FK with possibly-IK-overridden angles) ──
            val leftElbow  = leftShoulder + angleToOffset(laUA, upperArmLen)
            val leftHand   = leftElbow   + angleToOffset(laFA, forearmLen)
            val rightElbow = rightShoulder + angleToOffset(raUA, upperArmLen)
            val rightHand  = rightElbow  + angleToOffset(raFA, forearmLen)
            val leftKnee   = leftHip     + angleToOffset(llUA, upperLegLen)
            val leftFoot   = leftKnee    + angleToOffset(llLA, lowerLegLen)
            val rightKnee  = rightHip    + angleToOffset(rlUA, upperLegLen)
            val rightFoot  = rightKnee   + angleToOffset(rlLA, lowerLegLen)

            // ── Eye tracking (idle wander only) ──
            val isThinking = state.mode == RobotMode.THINKING
            val (pupilDx, pupilDy) = if (isThinking) {
                (thinkPhase.value * headR * 0.15f) to (-headR * 0.55f)
            } else {
                val angle = idleWander.value * PI.toFloat()
                (cos(angle) * headR * 0.08f) to (sin(angle * 1.7f) * headR * 0.06f)
            }

            // ═══════════════════════════════════════════════════════
            //  DRAW ORDER: back to front (ground already drawn above)
            // ═══════════════════════════════════════════════════════

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
            // Hip connectors — bridge body to leg joints
            drawLine(
                color = ColorStickBody,
                start = hip,
                end = leftHip,
                strokeWidth = LIMB_STROKE,
                cap = StrokeCap.Round
            )
            drawLine(
                color = ColorStickBody,
                start = hip,
                end = rightHip,
                strokeWidth = LIMB_STROKE,
                cap = StrokeCap.Round
            )

            // ── Shoulder connectors — bridge body to arm joints ──
            drawLine(
                color = ColorStickBody,
                start = neck,
                end = leftShoulder,
                strokeWidth = LIMB_STROKE,
                cap = StrokeCap.Round
            )
            drawLine(
                color = ColorStickBody,
                start = neck,
                end = rightShoulder,
                strokeWidth = LIMB_STROKE,
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

            // ── Face (skip for back view when walking AWAY) ──
            if (walkType != WalkType.AWAY) {
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
                    blinkAmount = blinkProgress.value,
                    isSideView = walkType == WalkType.LEFT || walkType == WalkType.RIGHT,
                    facingRight = walkType == WalkType.RIGHT
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
        val statusText = if (!enginesReady) {
            "小火正在醒来..."
        } else when (state.mode) {
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
    val headShiftX: Float = 0f,        // horizontal head offset (px)
    val headShiftY: Float = 0f,        // vertical head offset (px)
    val neckShiftX: Float = 0f,        // body lean (px)
    val hipShiftX: Float = 0f,         // hip horizontal (px)
    val hipShiftY: Float = 0f,         // hip vertical fine-tune (px)
    val bodyScale: Float = 0f,         // 0=normal, >0=compress body (0-1 range)
    val figureRotation: Float = 0f,    // whole-body rotation degrees (90=lying down)
    val leftUpperArmAngle: Float,      // from shoulder
    val leftForearmAngle: Float,
    val rightUpperArmAngle: Float,
    val rightForearmAngle: Float,
    val leftUpperLegAngle: Float,      // from hip
    val leftLowerLegAngle: Float,
    val rightUpperLegAngle: Float,
    val rightLowerLegAngle: Float,
)

// ═══════════════════════════════════════════════════════════════
//  2-BONE IK SOLVER
// ═══════════════════════════════════════════════════════════════

/** Result of a 2-bone IK solve */
private data class IkResult(
    val angle1: Float,  // upper segment angle (rad, 0=straight-down, +=CW)
    val angle2: Float   // lower segment angle
)

/**
 * 2-Bone Inverse Kinematics.
 *
 * Given root, L1, L2, and a target, returns joint angles that place
 * the end-effector exactly at the target.
 *
 * @param root   shoulder or hip position (screen pixels)
 * @param len1   upper segment length (upper arm / thigh)
 * @param len2   lower segment length (forearm / calf)
 * @param target desired end-effector position (hand / foot)
 * @param bendCCW true = elbow/knee bends CCW (left leg, left arm),
 *                false = bends CW (right side)
 * @return (upperAngle, lowerAngle) in pose-system convention, or null
 */
private fun solve2BoneIK(
    root: Offset, len1: Float, len2: Float,
    target: Offset, bendCCW: Boolean
): IkResult? {
    val dx = target.x - root.x
    val dy = target.y - root.y
    val dist = sqrt(dx * dx + dy * dy)

    // Unreachable
    val minReach = abs(len1 - len2) + 1f
    val maxReach = len1 + len2
    if (dist < minReach || dist > maxReach * 1.01f) return null
    val d = dist.coerceIn(minReach, maxReach)

    // ── Shoulder/hip angle ──
    // targetAngle: direction from root to target (0=down, +=CW)
    val targetAngle = atan2(dx, dy)

    // compensation: angle between L1 and root→target line
    val cosComp = ((len1 * len1 + d * d - len2 * len2) / (2f * len1 * d))
        .coerceIn(-1f, 1f)
    val compensation = acos(cosComp)

    // Choose bend direction
    val sign = if (bendCCW) -1f else 1f
    val angle1 = targetAngle - sign * compensation

    // ── Forearm/calf angle: point elbow→target ──
    val elbowX = root.x + len1 * sin(angle1)
    val elbowY = root.y + len1 * cos(angle1)
    val angle2 = atan2(target.x - elbowX, target.y - elbowY)

    return IkResult(angle1, angle2)
}

/** IDLE: relaxed standing with visible elbow/knee bends */
private fun idlePose(): StickPose = StickPose(
    // Arms: upper arm out, forearm in = clear elbow V-shape (~35° bend)
    leftUpperArmAngle  = Math.toRadians((-22.0)).toFloat(),
    leftForearmAngle   = Math.toRadians(14.0).toFloat(),
    rightUpperArmAngle = Math.toRadians(22.0).toFloat(),
    rightForearmAngle  = Math.toRadians((-14.0)).toFloat(),
    // Legs: slight knee bend (~8°), visible but natural
    leftUpperLegAngle  = Math.toRadians((-5.0)).toFloat(),
    leftLowerLegAngle  = Math.toRadians(3.0).toFloat(),
    rightUpperLegAngle = Math.toRadians(5.0).toFloat(),
    rightLowerLegAngle = Math.toRadians((-3.0)).toFloat(),
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
        rightUpperArmAngle = Math.toRadians(22.0).toFloat(),   // relaxed natural bend
        rightForearmAngle  = Math.toRadians((-14.0)).toFloat(),
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
        leftUpperArmAngle  = Math.toRadians((-22.0)).toFloat(),   // relaxed natural bend
        leftForearmAngle   = Math.toRadians(14.0).toFloat(),
        rightUpperArmAngle = Math.toRadians((-70.0)).toFloat(),   // bent up to chin
        rightForearmAngle  = Math.toRadians(60.0).toFloat(),      // hand under chin
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
    leftUpperArmAngle  = Math.toRadians((-22.0)).toFloat(),   // relaxed natural bend
    leftForearmAngle   = Math.toRadians(14.0).toFloat(),
    rightUpperArmAngle = Math.toRadians((-75.0)).toFloat(),   // hand above eyes
    rightForearmAngle  = Math.toRadians((-30.0)).toFloat(),   // visor pose
    leftUpperLegAngle  = Math.toRadians((-2.0)).toFloat(),
    leftLowerLegAngle  = 0f,
    rightUpperLegAngle = Math.toRadians(4.0).toFloat(),
    rightLowerLegAngle = 0f,
)

/** JUMPING: phases 0=crouch → 0.25=launch → 0.6=apex → 1.0=land */
private fun jumpingPose(phase: Float): StickPose {
    val crouch = (1f - (phase / 0.25f).coerceIn(0f, 1f)) * 0.5f  // 0.5 at phase 0, 0 at 0.25
    val launch = ((phase - 0.15f) / 0.45f).coerceIn(0f, 1f)       // 0→1 from launch to apex
    val tuck  = ((phase - 0.4f) / 0.2f).coerceIn(0f, 1f)          // leg tuck at apex
    return StickPose(
        headTilt = 0f,
        headShiftX = 0f,
        headShiftY = crouch * 14f - launch * 8f,  // crouch→lower, launch→stretch
        neckShiftX = 0f, hipShiftX = 0f,
        hipShiftY = crouch * 8f,
        bodyScale = crouch * 0.35f,                // compress during crouch
        figureRotation = 0f,
        // Arms: back during crouch → up during launch/apex
        leftUpperArmAngle  = Math.toRadians((-15.0 + crouch * 30 - launch * 115)).toFloat(),
        leftForearmAngle   = Math.toRadians((8.0 - launch * 100)).toFloat(),
        rightUpperArmAngle = Math.toRadians((15.0 - crouch * 30 + launch * 115)).toFloat(),
        rightForearmAngle  = Math.toRadians((-8.0 + launch * 100)).toFloat(),
        // Legs: straight during crouch → tuck at apex
        leftUpperLegAngle  = Math.toRadians((-3.0 + tuck * 30).toDouble()).toFloat(),
        leftLowerLegAngle  = Math.toRadians((-tuck * 35).toDouble()).toFloat(),
        rightUpperLegAngle = Math.toRadians((3.0 - tuck * 30).toDouble()).toFloat(),
        rightLowerLegAngle = Math.toRadians((tuck * 35).toDouble()).toFloat(),
    )
}

/** Vertical offset for jump: parabolic arc, negative = upward */
private fun jumpOffsetY(phase: Float, figureHeight: Float): Float {
    if (phase <= 0f || phase >= 1f) return 0f
    // Peak at phase ~0.55
    val t = (phase / 0.55f).coerceIn(0f, 1f)
    return -sin(t * PI.toFloat()) * figureHeight * 0.35f
}

/** SQUATTING: knees bent deep, hands on knees, feet planted (IK) */
private fun squattingPose(): StickPose = StickPose(
    headTilt = 0f,
    headShiftX = 0f, headShiftY = 8f,
    neckShiftX = 0f, hipShiftX = 0f, hipShiftY = 0f,
    bodyScale = 0f,         // no compress — IK places feet; squat comes from knee bend
    figureRotation = 0f,
    leftUpperArmAngle  = Math.toRadians((-20.0)).toFloat(),
    leftForearmAngle   = Math.toRadians((-80.0)).toFloat(),  // hands to knees
    rightUpperArmAngle = Math.toRadians(20.0).toFloat(),
    rightForearmAngle  = Math.toRadians(80.0).toFloat(),     // hands to knees
    leftUpperLegAngle  = Math.toRadians((-55.0)).toFloat(),  // thigh bent (IK override)
    leftLowerLegAngle  = Math.toRadians(50.0).toFloat(),     // calf angled back
    rightUpperLegAngle = Math.toRadians(55.0).toFloat(),     // thigh bent (IK override)
    rightLowerLegAngle = Math.toRadians((-50.0)).toFloat(),  // calf angled back
)

/** LOUNGING: leaning against left screen edge like a wall. Body at ~18° above horizontal, hips and knees bent for a natural relaxed look. */
private fun lyingPose(): StickPose = StickPose(
    headTilt = Math.toRadians((-22.0)).toFloat(),     // head resting on "wall"
    headShiftX = 0f, headShiftY = 0f,
    neckShiftX = 0f, hipShiftX = 0f, hipShiftY = 0f,
    bodyScale = 0f,
    figureRotation = -72f,                              // lean against left edge (~18° above flat)
    // Left arm: propping body up, elbow planted
    leftUpperArmAngle  = Math.toRadians((-105.0)).toFloat(),  // reach back to prop
    leftForearmAngle   = Math.toRadians((-65.0)).toFloat(),   // forearm planted
    // Right arm: relaxed across body
    rightUpperArmAngle = Math.toRadians(25.0).toFloat(),
    rightForearmAngle  = Math.toRadians((-30.0)).toFloat(),
    // Legs: hips bent so legs hang more downward, knees bent naturally
    leftUpperLegAngle  = Math.toRadians((-48.0)).toFloat(),   // thigh angled down from hip
    leftLowerLegAngle  = Math.toRadians(62.0).toFloat(),      // shin hangs near vertical
    rightUpperLegAngle = Math.toRadians(48.0).toFloat(),      // thigh angled down from hip
    rightLowerLegAngle = Math.toRadians((-62.0)).toFloat(),   // shin hangs near vertical
)

/** WAKING UP: both hands rubbing eyes, groggy head tilt, relaxed stance */
private fun wakingUpPose(): StickPose = StickPose(
    headTilt = Math.toRadians((-8.0)).toFloat(),      // groggy tilt
    headShiftX = 0f, headShiftY = 3f,                 // head slightly tucked
    neckShiftX = 0f, hipShiftX = 0f, hipShiftY = 0f,
    bodyScale = 0f, figureRotation = 0f,
    // Arms: elbows out to sides, hands reaching toward face (IK fine-tunes to eyes)
    leftUpperArmAngle  = Math.toRadians((-72.0)).toFloat(),
    leftForearmAngle   = Math.toRadians((-35.0)).toFloat(),
    rightUpperArmAngle = Math.toRadians(72.0).toFloat(),
    rightForearmAngle  = Math.toRadians(35.0).toFloat(),
    // Legs: relaxed standing
    leftUpperLegAngle  = Math.toRadians((-2.0)).toFloat(),
    leftLowerLegAngle  = Math.toRadians(0.0).toFloat(),
    rightUpperLegAngle = Math.toRadians(2.0).toFloat(),
    rightLowerLegAngle = Math.toRadians(0.0).toFloat(),
)

/** WALKING front-facing: alternating limb swing. Used for depth walks (away/toward). */
private fun walkingPose(phase: Float): StickPose {
    val gaitCycles = 3f
    val gaitPhase = phase * gaitCycles * 2f * PI.toFloat()
    val swing = sin(gaitPhase)
    val bob = abs(swing)
    val legSwing = swing * 32f
    val armSwing = swing * 28f
    val kneeBend = bob * 10f

    return StickPose(
        headTilt = Math.toRadians((swing * 3.0)).toFloat(),
        headShiftX = 0f, headShiftY = -bob * 5f,
        neckShiftX = 0f, hipShiftX = 0f, hipShiftY = 0f,
        bodyScale = bob * 0.06f, figureRotation = 0f,
        leftUpperArmAngle  = Math.toRadians((-22.0 - armSwing)).toFloat(),
        leftForearmAngle   = Math.toRadians((14.0 + armSwing * 0.5)).toFloat(),
        rightUpperArmAngle = Math.toRadians((22.0 - armSwing)).toFloat(),
        rightForearmAngle  = Math.toRadians((-14.0 - armSwing * 0.5)).toFloat(),
        leftUpperLegAngle  = Math.toRadians((-5.0 - legSwing)).toFloat(),
        leftLowerLegAngle  = Math.toRadians(kneeBend.toDouble()).toFloat(),
        rightUpperLegAngle = Math.toRadians((5.0 - legSwing)).toFloat(),
        rightLowerLegAngle = Math.toRadians((-kneeBend).toDouble()).toFloat(),
    )
}

/** WALKING side-profile: both arms on walking side, body leans forward. Used for LEFT/RIGHT. */
private fun walkingSidePose(phase: Float, facingLeft: Boolean): StickPose {
    val gaitCycles = 3f
    val gaitPhase = phase * gaitCycles * 2f * PI.toFloat()
    val swing = sin(gaitPhase)
    val bob = abs(swing)

    val sign = if (facingLeft) -1f else 1f    // direction multiplier
    val legSwing = swing * 38f                // stronger stride in side view
    val armSwing = swing * 32f
    val kneeBend = bob * 12f
    val armBase: Float = sign * 8f            // slight forward arm bias

    return StickPose(
        headTilt = Math.toRadians((swing * 2.0 + sign * 8.0)).toFloat(),  // slight turn
        headShiftX = sign * 4f,             // shift face toward walking direction
        headShiftY = -bob * 5f,
        neckShiftX = sign * 2.5f,           // body lean forward
        hipShiftX = sign * 2f,
        hipShiftY = 0f,
        bodyScale = bob * 0.06f,
        figureRotation = 0f,
        // Both arms on the same side, swinging together like pendulums
        leftUpperArmAngle  = Math.toRadians(((-22.0 * sign) - armSwing + armBase)).toFloat(),
        leftForearmAngle   = Math.toRadians(((14.0 * sign) + armSwing * 0.4)).toFloat(),
        rightUpperArmAngle = Math.toRadians(((-18.0 * sign) - armSwing + armBase)).toFloat(),
        rightForearmAngle  = Math.toRadians(((10.0 * sign) + armSwing * 0.4)).toFloat(),
        // Legs: alternating stride
        leftUpperLegAngle  = Math.toRadians((-5.0 - legSwing)).toFloat(),
        leftLowerLegAngle  = Math.toRadians(kneeBend.toDouble()).toFloat(),
        rightUpperLegAngle = Math.toRadians((3.0 - legSwing)).toFloat(),
        rightLowerLegAngle = Math.toRadians((-kneeBend).toDouble()).toFloat(),
    )
}

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
        hipShiftY  = a.hipShiftY  + (b.hipShiftY  - a.hipShiftY)  * t,
        bodyScale  = a.bodyScale  + (b.bodyScale  - a.bodyScale)  * t,
        figureRotation = a.figureRotation + (b.figureRotation - a.figureRotation) * t,
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

/** Float modulo that always returns a non-negative remainder */
private fun wrapMod(value: Float, range: Float): Float {
    var v = value % range
    if (v < 0) v += range
    return v
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
    breatheAmount: Float,
    anticTrigger: Long = 0L,
    jumpPhase: Float = 0f,
    enginesReady: Boolean = true,
    walkType: WalkType = WalkType.NONE,
    walkPhase: Float = 0f
): StickPose {
    // Engines not ready → waking up animation (overrides everything)
    if (!enginesReady) return wakingUpPose()

    // Walking animation (overrides mode/emotion during walk)
    if (walkType == WalkType.LEFT)  return walkingSidePose(walkPhase, facingLeft = true)
    if (walkType == WalkType.RIGHT) return walkingSidePose(walkPhase, facingLeft = false)
    if (walkType == WalkType.AWAY || walkType == WalkType.TOWARD) return walkingPose(walkPhase)

    // Base pose from mode
    val modePose = when (mode) {
        RobotMode.IDLE -> {
            // Jump takes priority when active
            if (jumpPhase > 0.01f) {
                jumpingPose(jumpPhase)
            } else when {
                anticTrigger > 0 && anticTrigger % 7L == 3L -> squattingPose()
                anticTrigger > 3 && anticTrigger % 13L == 7L -> lyingPose()
                else -> idlePose()
            }
        }
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
    // Subtle elbow/knee dot — fills the inner bend gap
    drawCircle(
        color = ColorStickBody,
        radius = endRadius * 0.5f,
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

    // Blush for happy/shy — radial gradient from pink center → transparent edge
    if (emotion == Emotion.HAPPY || emotion == Emotion.SHY) {
        val blushR = radius * 0.22f
        val blushY = center.y + radius * 0.05f
        val blushXOff = radius * 0.55f
        val blushCenter = Color(0x55CC3333)
        val blushEdge   = Color(0x00CC3333)
        val leftCenter  = Offset(center.x - blushXOff, blushY)
        val rightCenter = Offset(center.x + blushXOff, blushY)
        drawCircle(
            brush = Brush.radialGradient(
                colors = listOf(blushCenter, blushEdge),
                center = leftCenter,
                radius = blushR
            ),
            radius = blushR,
            center = leftCenter
        )
        drawCircle(
            brush = Brush.radialGradient(
                colors = listOf(blushCenter, blushEdge),
                center = rightCenter,
                radius = blushR
            ),
            radius = blushR,
            center = rightCenter
        )
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
    blinkAmount: Float,
    isSideView: Boolean = false,
    facingRight: Boolean = false
) {
    // ── Side profile: single eye + shifted mouth ──
    if (isSideView) {
        val sign = if (facingRight) 1f else -1f
        val eyeXOff = headRadius * 0.3f
        val eyeY = headCenter.y - headRadius * 0.12f
        val sideEyeCenter = Offset(headCenter.x + sign * eyeXOff, eyeY)

        val lidScale = when (emotion) {
            Emotion.SLEEPY -> 0.4f + blinkAmount * 0.6f
            Emotion.SHY    -> 0.35f + blinkAmount * 0.65f
            Emotion.HAPPY  -> 0.2f + blinkAmount * 0.8f
            else -> blinkAmount
        }
        if (lidScale < 0.95f) {
            drawStickEye(sideEyeCenter, pupilDx, pupilDy, eyeRadius * 1.15f, lidScale, emotion)
        }

        // Small profile mouth line on the near side
        val mouthY = headCenter.y + headRadius * 0.35f
        val mouthCx = headCenter.x + sign * headRadius * 0.18f
        drawStickMouth(
            cx = mouthCx, mouthY = mouthY,
            halfWidth = mouthHalfW * 0.6f,
            emotion = emotion,
            isSpeaking = isSpeaking,
            speakAmount = speakAmount
        )
        return
    }

    // ── Front view: two eyes ──
    val eyeY = headCenter.y - headRadius * 0.15f
    val eyeXOff = headRadius * 0.38f
    val leftEyeCenter  = Offset(headCenter.x - eyeXOff, eyeY)
    val rightEyeCenter = Offset(headCenter.x + eyeXOff, eyeY)

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
        val browLen = eyeRadius * 1.8f
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
    // ── Speaking: emoji-style filled oval cavity + teeth ──
    if (isSpeaking) {
        val rx = halfWidth * 0.8f
        val baseRy = halfWidth * 0.55f
        val scale = 0.7f + speakAmount * 0.3f
        val ry = baseRy * scale

        // Dark filled mouth cavity
        drawOval(
            color = ColorMouth,
            topLeft = Offset(cx - rx, mouthY - ry),
            size = Size(rx * 2f, ry * 2f),
        )

        // White upper-tooth band — continuous bar across top of cavity
        val barW = rx * 1.88f
        val barH = ry * 0.84f
        drawRoundRect(
            color = Color.White,
            topLeft = Offset(cx - barW / 2f, mouthY - ry * 0.75f),
            size = Size(barW, barH),
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(barH * 0.35f, barH * 0.35f),
        )

        // Tongue visible when mouth is open wider
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

/** Ground line across the canvas at foot level */
private fun DrawScope.drawGroundLine(cx: Float, feetY: Float, canvasW: Float) {
    val groundW = canvasW * 0.7f
    val x0 = cx - groundW / 2f
    val x1 = cx + groundW / 2f
    // Subtle center-weighted fade: bright in the middle, fading to edges
    drawLine(
        color = ColorStickBody.copy(alpha = 0.1f),
        start = Offset(x0, feetY),
        end = Offset(x1, feetY),
        strokeWidth = 2f,
        cap = StrokeCap.Round
    )
    // Thin shadow line just below
    drawLine(
        color = ColorShadow,
        start = Offset(x0, feetY + 3f),
        end = Offset(x1, feetY + 3f),
        strokeWidth = 8f,
        cap = StrokeCap.Round
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
