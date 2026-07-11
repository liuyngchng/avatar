//
//  FaceParts.swift
//  Avatar
//
//  Stick figure drawing — ported from Android RobotFaceScreen.kt.
//  Uses CoreGraphics to draw an animated stick figure with emotion,
//  pose system, IK solver, and mode indicators.
//

import Foundation
import CoreGraphics
import UIKit

// MARK: - Color Palette

enum StickColors {
    static let bg          = UIColor(red: 0.10, green: 0.10, blue: 0.18, alpha: 1.0)  // #1A1A2E
    static let stickBody   = UIColor(red: 0.95, green: 0.80, blue: 0.24, alpha: 1.0)  // #F2CC3D emoji yellow
    static let headFill    = UIColor(red: 1.00, green: 0.88, blue: 0.40, alpha: 1.0)  // #FFE066 light yellow
    static let headStroke  = UIColor(red: 0.87, green: 0.72, blue: 0.00, alpha: 1.0)  // #DDB800 golden outline
    static let eye         = UIColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1.0)  // #333333 soft charcoal
    static let mouth       = UIColor(red: 0.27, green: 0.27, blue: 0.27, alpha: 1.0)  // #444444 emoji dark (lines & cavities)
    static let shadow      = UIColor(red: 0.00, green: 0.00, blue: 0.00, alpha: 0.09) // ground shadow
    static let accent      = UIColor(red: 0.40, green: 0.67, blue: 1.00, alpha: 1.0)  // #66AAFF
    static let tongue      = UIColor(red: 1.00, green: 0.42, blue: 0.54, alpha: 1.0)  // #FF6B8A
    static let lookingColor = UIColor(red: 0.40, green: 0.87, blue: 0.40, alpha: 1.0) // #66DD66
    static let blush       = UIColor(red: 0.91, green: 0.40, blue: 0.40, alpha: 0.33) // blush center — radial gradient fades to 0
}

// MARK: - Cached Gradients

enum StickGradients {
    static let head: CGGradient = {
        let colors = [StickColors.headFill.cgColor,
                      UIColor(red: 0.91, green: 0.75, blue: 0.18, alpha: 1.0).cgColor] as CFArray // #E8BF2E
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors, locations: [0, 1])!
    }()
}

// MARK: - Geometry Constants (relative to view size)

enum StickGeo {
    static let figureHeightFrac: CGFloat = 0.52
    static let feetYFrac: CGFloat        = 0.82
    static let headRadiusFrac: CGFloat   = 0.085
    static let bodyLengthFrac: CGFloat   = 0.19  // neck→hip (tuned so legs reach ground)
    static let upperArmFrac: CGFloat     = 0.10
    static let forearmFrac: CGFloat      = 0.09
    static let upperLegFrac: CGFloat     = 0.13
    static let lowerLegFrac: CGFloat     = 0.12
    static let shoulderWFrac: CGFloat    = 0.06
    static let hipWFrac: CGFloat         = 0.04

    static let bodyStroke: CGFloat   = 6
    static let limbStroke: CGFloat   = 5
    static let jointRadius: CGFloat  = limbStroke * 0.8   // hand/foot end cap
    static let eyeRadiusFrac: CGFloat   = 0.018
    static let mouthWFrac: CGFloat      = 0.045
}

// MARK: - Walk Direction

enum WalkType {
    case none, left, right, away, toward
}

// MARK: - Stick Pose Data

struct StickPose {
    var headTilt: CGFloat = 0
    var headShiftX: CGFloat = 0
    var headShiftY: CGFloat = 0
    var neckShiftX: CGFloat = 0
    var hipShiftX: CGFloat = 0
    var hipShiftY: CGFloat = 0
    var bodyScale: CGFloat = 0         // 0..1 compress body
    var figureRotation: CGFloat = 0    // degrees, whole-body rotation
    var leftUpperArmAngle: CGFloat = 0
    var leftForearmAngle: CGFloat = 0
    var rightUpperArmAngle: CGFloat = 0
    var rightForearmAngle: CGFloat = 0
    var leftUpperLegAngle: CGFloat = 0
    var leftLowerLegAngle: CGFloat = 0
    var rightUpperLegAngle: CGFloat = 0
    var rightLowerLegAngle: CGFloat = 0
}

// MARK: - IK Result

struct IkResult {
    let angle1: CGFloat  // upper segment
    let angle2: CGFloat  // lower segment
}

// MARK: - Main Drawer

final class StickFigureDrawer {

    // ── Pose Engine ──────────────────────────────────────────

    /// Convert polar angle (0=down, +=CW) to cartesian offset
    private static func angleToOffset(_ angleRad: CGFloat, _ length: CGFloat) -> CGPoint {
        return CGPoint(x: sin(angleRad) * length, y: cos(angleRad) * length)
    }

    /// 2-Bone Inverse Kinematics solver
    private static func solve2BoneIK(
        root: CGPoint, len1: CGFloat, len2: CGFloat,
        target: CGPoint, bendCCW: Bool
    ) -> IkResult? {
        let dx = target.x - root.x
        let dy = target.y - root.y
        let dist = sqrt(dx * dx + dy * dy)

        let minReach = abs(len1 - len2) + 1
        let maxReach = len1 + len2
        guard dist >= minReach && dist <= maxReach * 1.01 else { return nil }
        let d = min(max(dist, minReach), maxReach)

        let targetAngle = atan2(dx, dy)

        let cosComp = max(-1, min(1, (len1 * len1 + d * d - len2 * len2) / (2 * len1 * d)))
        let compensation = acos(cosComp)
        let sign: CGFloat = bendCCW ? -1 : 1
        let angle1 = targetAngle - sign * compensation

        let elbowX = root.x + len1 * sin(angle1)
        let elbowY = root.y + len1 * cos(angle1)
        let angle2 = atan2(target.x - elbowX, target.y - elbowY)

        return IkResult(angle1: angle1, angle2: angle2)
    }

    /// Linearly interpolate two angles along the shortest arc
    private static func lerpAngle(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        var diff = b - a
        while diff > .pi { diff -= 2 * .pi }
        while diff < -.pi { diff += 2 * .pi }
        return a + diff * t
    }

    // ── Base Poses ───────────────────────────────────────────

    private static func idlePose() -> StickPose {
        StickPose(
            leftUpperArmAngle: deg2rad(-22), leftForearmAngle: deg2rad(14),
            rightUpperArmAngle: deg2rad(22), rightForearmAngle: deg2rad(-14),
            leftUpperLegAngle: deg2rad(-5), leftLowerLegAngle: deg2rad(3),
            rightUpperLegAngle: deg2rad(5), rightLowerLegAngle: deg2rad(-3)
        )
    }

    private static func listeningPose(_ pulse: CGFloat) -> StickPose {
        let lean: CGFloat = 4 + pulse * 4
        return StickPose(
            headTilt: deg2rad(-6 - Double(pulse) * 4),
            neckShiftX: lean * 1.5, hipShiftX: lean * 0.8,
            leftUpperArmAngle: deg2rad(-90 - Double(pulse) * 15),
            leftForearmAngle: deg2rad(-30),
            rightUpperArmAngle: deg2rad(22), rightForearmAngle: deg2rad(-14),
            leftUpperLegAngle: deg2rad(-2), leftLowerLegAngle: 0,
            rightUpperLegAngle: deg2rad(5), rightLowerLegAngle: 0
        )
    }

    /// Speaking pose with varied, natural arm gestures driven by a slow gesture phase.
    /// - Parameters:
    ///   - speakAmount: 0.15..1.0 mouth-open signal (toggles at speech rate, ~3Hz)
    ///   - gesturePhase: 0→1 continuous slow cycle (~3s period) for arm variety
    ///   - emphasisArm: -1=none, 0=left arm raise, 1=right arm raise
    ///   - emphasisPhase: 0→1 raise progress (sin-eased)
    private static func speakingPose(_ speakAmount: CGFloat, gesturePhase: CGFloat = 0,
                                      emphasisArm: Int = -1, emphasisPhase: CGFloat = 0) -> StickPose {
        let gp = gesturePhase * 2 * .pi   // gesture phase in radians

        // Multiple slow oscillators at incommensurate frequencies → complex non-repeating patterns
        let slow1 = sin(gp * 0.7)         // ~4.3s period
        let slow2 = cos(gp * 1.1)         // ~2.7s period
        let slow3 = sin(gp * 1.5)         // ~2.0s period

        // Gesture energy envelope: slowly fades gestures in and out for natural rest periods
        let energy = slow1 * 0.5 + 0.5    // 0..1 smooth fade

        // Right arm: blend of two oscillators + mouth-sync for emphasis on open mouth
        let mouthKick = (speakAmount > 0.5 ? 1.0 : 0.3)  // bigger gestures when "mouth open"
        var rightSwing = (sin(gp * 2.3) * 0.7 + slow2 * 0.3) * 22 * energy * mouthKick

        // Left arm: different rhythm — sometimes mirrors right, sometimes independent
        var leftSwing = (cos(gp * 1.9) * 0.6 + slow3 * 0.4) * 16 * energy * mouthKick

        // ── Emphasis gesture: occasional arm raise like a speaker making a point ──
        if emphasisArm >= 0 && emphasisPhase > 0.01 {
            let ease = sin(emphasisPhase * .pi)   // sin curve: 0→1→0, smooth raise & lower
            if emphasisArm == 0 {
                // Left arm raise: blend from current swing toward raised position (-80°)
                leftSwing = leftSwing * (1 - ease) + (-80 - (-18)) * ease
            } else {
                // Right arm raise: blend toward +80°
                rightSwing = rightSwing * (1 - ease) + (80 - 18) * ease
            }
        }

        // Head follows the more active arm + subtle independent tilt
        let headFollow = (abs(rightSwing) > abs(leftSwing) ? rightSwing : leftSwing) * 0.12

        // Compute forearm angles with emphasis override
        var leftFore = -20 - leftSwing * 0.5
        var rightFore = 25 + rightSwing * 0.6
        if emphasisArm == 0 && emphasisPhase > 0.01 {
            let ease = sin(emphasisPhase * .pi)
            leftFore = leftFore * (1 - ease) + (-25) * ease
        } else if emphasisArm == 1 && emphasisPhase > 0.01 {
            let ease = sin(emphasisPhase * .pi)
            rightFore = rightFore * (1 - ease) + 25 * ease
        }

        return StickPose(
            headTilt: deg2rad(Double(headFollow)),
            leftUpperArmAngle: deg2rad(-18 - Double(leftSwing)),
            leftForearmAngle: deg2rad(Double(leftFore)),
            rightUpperArmAngle: deg2rad(18 + Double(rightSwing)),
            rightForearmAngle: deg2rad(Double(rightFore)),
            leftUpperLegAngle: deg2rad(-2), leftLowerLegAngle: 0,
            rightUpperLegAngle: deg2rad(2), rightLowerLegAngle: 0
        )
    }

    private static func thinkingPose(_ phase: CGFloat) -> StickPose {
        StickPose(
            headTilt: deg2rad(-8 + Double(phase) * 4),
            headShiftX: phase * 3, headShiftY: -3,
            neckShiftX: phase * 2, hipShiftX: phase * 1.5,
            leftUpperArmAngle: deg2rad(-22), leftForearmAngle: deg2rad(14),
            rightUpperArmAngle: deg2rad(-70), rightForearmAngle: deg2rad(60),
            leftUpperLegAngle: deg2rad(-2), leftLowerLegAngle: 0,
            rightUpperLegAngle: deg2rad(2), rightLowerLegAngle: 0
        )
    }

    private static func lookingPose() -> StickPose {
        StickPose(
            headShiftY: -4, neckShiftX: 6, hipShiftX: 3,
            leftUpperArmAngle: deg2rad(-22), leftForearmAngle: deg2rad(14),
            rightUpperArmAngle: deg2rad(-75), rightForearmAngle: deg2rad(-30),
            leftUpperLegAngle: deg2rad(-2), leftLowerLegAngle: 0,
            rightUpperLegAngle: deg2rad(4), rightLowerLegAngle: 0
        )
    }

    private static func jumpingPose(_ phase: CGFloat) -> StickPose {
        let crouch = (1 - min(phase / 0.25, 1)) * 0.5
        let launch = min(max((phase - 0.15) / 0.45, 0), 1)
        let tuck   = min(max((phase - 0.4) / 0.2, 0), 1)
        return StickPose(
            headShiftY: crouch * 14 - launch * 8,
            hipShiftY: crouch * 8, bodyScale: crouch * 0.35,
            leftUpperArmAngle: deg2rad(-15 + Double(crouch) * 30 - Double(launch) * 115),
            leftForearmAngle: deg2rad(8 - Double(launch) * 100),
            rightUpperArmAngle: deg2rad(15 - Double(crouch) * 30 + Double(launch) * 115),
            rightForearmAngle: deg2rad(-8 + Double(launch) * 100),
            leftUpperLegAngle: deg2rad(-3 + Double(tuck) * 30),
            leftLowerLegAngle: deg2rad(-Double(tuck) * 35),
            rightUpperLegAngle: deg2rad(3 - Double(tuck) * 30),
            rightLowerLegAngle: deg2rad(Double(tuck) * 35)
        )
    }

    /// Vertical offset for jump: parabolic arc, negative = upward
    static func jumpOffsetY(_ phase: CGFloat, _ figureHeight: CGFloat) -> CGFloat {
        guard phase > 0 && phase < 1 else { return 0 }
        let t = min(phase / 0.55, 1)
        return -sin(t * .pi) * figureHeight * 0.35
    }

    private static func squattingPose() -> StickPose {
        StickPose(
            headShiftY: 8, bodyScale: 0,  // no compress — IK places feet; squat from knee bend
            leftUpperArmAngle: deg2rad(-20), leftForearmAngle: deg2rad(-80),
            rightUpperArmAngle: deg2rad(20), rightForearmAngle: deg2rad(80),
            leftUpperLegAngle: deg2rad(-55), leftLowerLegAngle: deg2rad(50),
            rightUpperLegAngle: deg2rad(55), rightLowerLegAngle: deg2rad(-50)
        )
    }

    /// LOUNGING: leaning against left screen edge like a wall. Body at ~18° above horizontal, hips and knees bent for a natural relaxed look.
    private static func lyingPose() -> StickPose {
        StickPose(
            headTilt: deg2rad(-22),                    // head resting on "wall"
            hipShiftY: -25,                             // raise hips so legs stay above ground after rotation
            figureRotation: -72,                        // lean against left edge (~18° above flat)
            // Left arm: propping body up, elbow planted
            leftUpperArmAngle: deg2rad(-105),           // reach back to prop
            leftForearmAngle: deg2rad(-65),             // forearm planted
            // Right arm: relaxed across body
            rightUpperArmAngle: deg2rad(25),
            rightForearmAngle: deg2rad(-30),
            // Legs: relaxed bent-knee lounging
            leftUpperLegAngle: deg2rad(-35),            // thigh angled down from hip
            leftLowerLegAngle: deg2rad(42),             // shin toward feet
            rightUpperLegAngle: deg2rad(35),            // thigh angled down from hip
            rightLowerLegAngle: deg2rad(-42)            // shin toward feet
        )
    }

    /// WAKING UP: both hands rubbing eyes, groggy head tilt, relaxed stance
    private static func wakingUpPose() -> StickPose {
        StickPose(
            headTilt: deg2rad(-8),          // groggy tilt
            headShiftY: 3,                  // head slightly tucked
            bodyScale: 0, figureRotation: 0,
            // Arms: elbows out to sides, hands reaching toward face (IK fine-tunes to eyes)
            leftUpperArmAngle: deg2rad(-72),
            leftForearmAngle: deg2rad(-35),
            rightUpperArmAngle: deg2rad(72),
            rightForearmAngle: deg2rad(35),
            // Legs: relaxed standing
            leftUpperLegAngle: deg2rad(-2), leftLowerLegAngle: deg2rad(0),
            rightUpperLegAngle: deg2rad(2), rightLowerLegAngle: deg2rad(0)
        )
    }

    /// WALKING: alternating limb swing driven by gait phase. Phase 0→1 maps to multiple gait cycles.
    private static func walkingPose(_ phase: CGFloat) -> StickPose {
        let gaitCycles: CGFloat = 3
        let gaitPhase = phase * gaitCycles * 2 * .pi
        let swing = sin(gaitPhase)         // -1..1, drives limb alternation
        let bob = abs(swing)               // 0..1, body bounce

        let legSwing = swing * 32          // ±32° leg arc
        let armSwing = swing * 28          // ±28° arm arc (opposite to legs — natural gait)
        let kneeBend = bob * 10            // knee flex during stride

        return StickPose(
            headTilt: deg2rad(Double(swing) * 3),
            headShiftY: -bob * 5,           // slight up-bounce each step
            bodyScale: bob * 0.06,          // micro-compression on step
            figureRotation: 0,
            // Arms: cross-crawl — opposite to same-side leg (natural human walking)
            leftUpperArmAngle: deg2rad(-22 - Double(armSwing)),
            leftForearmAngle: deg2rad(14 - Double(armSwing) * 0.5),
            rightUpperArmAngle: deg2rad(22 - Double(armSwing)),
            rightForearmAngle: deg2rad(-14 - Double(armSwing) * 0.5),
            // Legs: alternating stride
            leftUpperLegAngle: deg2rad(-5 - Double(legSwing)),
            leftLowerLegAngle: deg2rad(Double(kneeBend)),
            rightUpperLegAngle: deg2rad(5 + Double(legSwing)),
            rightLowerLegAngle: deg2rad(-Double(kneeBend))
        )
    }

    /// WALKING side-profile: both arms on walking side, body leans forward. Used for LEFT/RIGHT.
    private static func walkingSidePose(_ phase: CGFloat, facingLeft: Bool) -> StickPose {
        let gaitCycles: CGFloat = 3
        let gaitPhase = phase * gaitCycles * 2 * .pi
        let swing = sin(gaitPhase)
        let bob = abs(swing)

        let sign: CGFloat = facingLeft ? -1 : 1
        let legSwing = swing * 38
        let armSwing = swing * 32
        let kneeBend = bob * 12
        let armBase: CGFloat = sign * 8

        return StickPose(
            headTilt: deg2rad(Double(swing) * 2 + Double(sign) * 8),
            headShiftX: sign * 4,
            headShiftY: -bob * 5,
            neckShiftX: sign * 2.5,
            hipShiftX: sign * 2,
            hipShiftY: 0,
            bodyScale: bob * 0.06,
            figureRotation: 0,
            // Both arms on the same side, swinging together like pendulums
            leftUpperArmAngle: deg2rad(Double(-22 * sign) - Double(armSwing) + Double(armBase)),
            leftForearmAngle: deg2rad(Double(14 * sign) + Double(armSwing) * 0.4),
            rightUpperArmAngle: deg2rad(Double(-18 * sign) - Double(armSwing) + Double(armBase)),
            rightForearmAngle: deg2rad(Double(10 * sign) + Double(armSwing) * 0.4),
            // Legs: alternating stride
            leftUpperLegAngle: deg2rad(-5 - Double(legSwing)),
            leftLowerLegAngle: deg2rad(Double(kneeBend)),
            rightUpperLegAngle: deg2rad(3 + Double(legSwing)),
            rightLowerLegAngle: deg2rad(-Double(kneeBend))
        )
    }

    // ── Emotion Modifiers ────────────────────────────────────

    private static func emotionModifier(_ emotion: Emotion) -> StickPose {
        switch emotion {
        case .happy:
            return StickPose(
                headTilt: deg2rad(5), headShiftY: -5,
                leftUpperArmAngle: deg2rad(-20), leftForearmAngle: deg2rad(-15),
                rightUpperArmAngle: deg2rad(20), rightForearmAngle: deg2rad(15),
                leftUpperLegAngle: deg2rad(-5), leftLowerLegAngle: 0,
                rightUpperLegAngle: deg2rad(5), rightLowerLegAngle: 0
            )
        case .sad:
            return StickPose(
                headTilt: deg2rad(-10), headShiftY: 8,
                leftUpperArmAngle: deg2rad(5), leftForearmAngle: deg2rad(10),
                rightUpperArmAngle: deg2rad(-5), rightForearmAngle: deg2rad(-10),
                leftUpperLegAngle: 0, leftLowerLegAngle: 0,
                rightUpperLegAngle: 0, rightLowerLegAngle: 0
            )
        case .surprised:
            return StickPose(
                headShiftY: -8,
                leftUpperArmAngle: deg2rad(-40), leftForearmAngle: deg2rad(-50),
                rightUpperArmAngle: deg2rad(40), rightForearmAngle: deg2rad(50),
                leftUpperLegAngle: deg2rad(-6), leftLowerLegAngle: 0,
                rightUpperLegAngle: deg2rad(6), rightLowerLegAngle: 0
            )
        case .sleepy:
            return StickPose(
                headTilt: deg2rad(-5), headShiftY: 4,
                leftUpperArmAngle: deg2rad(8), leftForearmAngle: deg2rad(15),
                rightUpperArmAngle: deg2rad(-8), rightForearmAngle: deg2rad(-15),
                leftUpperLegAngle: 0, leftLowerLegAngle: 0,
                rightUpperLegAngle: 0, rightLowerLegAngle: 0
            )
        case .shy:
            return StickPose(
                headTilt: deg2rad(-8), headShiftY: 3,
                leftUpperArmAngle: deg2rad(5), leftForearmAngle: deg2rad(25),
                rightUpperArmAngle: deg2rad(-5), rightForearmAngle: deg2rad(-25),
                leftUpperLegAngle: deg2rad(3), leftLowerLegAngle: deg2rad(-3),
                rightUpperLegAngle: deg2rad(-3), rightLowerLegAngle: deg2rad(3)
            )
        case .curious:
            return StickPose(
                headTilt: deg2rad(8), headShiftY: -3,
                leftUpperArmAngle: deg2rad(-8), leftForearmAngle: deg2rad(5),
                rightUpperArmAngle: deg2rad(-60), rightForearmAngle: deg2rad(50),
                leftUpperLegAngle: deg2rad(-2), leftLowerLegAngle: 0,
                rightUpperLegAngle: deg2rad(2), rightLowerLegAngle: 0
            )
        case .goofy:
            return StickPose(
                headTilt: deg2rad(15), headShiftY: -3,
                leftUpperArmAngle: deg2rad(-120), leftForearmAngle: deg2rad(-90),
                rightUpperArmAngle: deg2rad(60), rightForearmAngle: deg2rad(-90),
                leftUpperLegAngle: deg2rad(-15), leftLowerLegAngle: deg2rad(10),
                rightUpperLegAngle: deg2rad(15), rightLowerLegAngle: deg2rad(-10)
            )
        default: // neutral
            return idlePose()
        }
    }

    /// Blend two poses with weight [t] (0=a, 1=b)
    private static func blendPose(_ a: StickPose, _ b: StickPose, _ t: CGFloat) -> StickPose {
        if t <= 0 { return a }
        if t >= 1 { return b }
        return StickPose(
            headTilt: a.headTilt + (b.headTilt - a.headTilt) * t,
            headShiftX: a.headShiftX + (b.headShiftX - a.headShiftX) * t,
            headShiftY: a.headShiftY + (b.headShiftY - a.headShiftY) * t,
            neckShiftX: a.neckShiftX + (b.neckShiftX - a.neckShiftX) * t,
            hipShiftX: a.hipShiftX + (b.hipShiftX - a.hipShiftX) * t,
            hipShiftY: a.hipShiftY + (b.hipShiftY - a.hipShiftY) * t,
            bodyScale: a.bodyScale + (b.bodyScale - a.bodyScale) * t,
            figureRotation: a.figureRotation + (b.figureRotation - a.figureRotation) * t,
            leftUpperArmAngle: lerpAngle(a.leftUpperArmAngle, b.leftUpperArmAngle, t),
            leftForearmAngle: lerpAngle(a.leftForearmAngle, b.leftForearmAngle, t),
            rightUpperArmAngle: lerpAngle(a.rightUpperArmAngle, b.rightUpperArmAngle, t),
            rightForearmAngle: lerpAngle(a.rightForearmAngle, b.rightForearmAngle, t),
            leftUpperLegAngle: lerpAngle(a.leftUpperLegAngle, b.leftUpperLegAngle, t),
            leftLowerLegAngle: lerpAngle(a.leftLowerLegAngle, b.leftLowerLegAngle, t),
            rightUpperLegAngle: lerpAngle(a.rightUpperLegAngle, b.rightUpperLegAngle, t),
            rightLowerLegAngle: lerpAngle(a.rightLowerLegAngle, b.rightLowerLegAngle, t)
        )
    }

    /// Compute the final pose for current state
    static func computePose(
        mode: RobotMode,
        emotion: Emotion,
        speakAmount: CGFloat,
        thinkPhase: CGFloat,
        listenPulse: CGFloat,
        breatheAmount: CGFloat,
        anticTrigger: Int = 0,
        jumpPhase: CGFloat = 0,
        enginesReady: Bool = true,
        walkType: WalkType = .none,
        walkPhase: CGFloat = 0,
        stageWalkPhase: CGFloat = 0,
        gesturePhase: CGFloat = 0,
        emphasisArm: Int = -1,
        emphasisPhase: CGFloat = 0
    ) -> StickPose {
        // Engines not ready → waking up animation (overrides everything)
        if !enginesReady { return wakingUpPose() }

        // Walking animation (overrides mode/emotion during walk)
        if walkType == .left  { return walkingSidePose(walkPhase, facingLeft: true) }
        if walkType == .right { return walkingSidePose(walkPhase, facingLeft: false) }
        if walkType == .away || walkType == .toward { return walkingPose(walkPhase) }

        let modePose: StickPose
        switch mode {
        case .idle:
            if jumpPhase > 0.01 {
                modePose = jumpingPose(jumpPhase)
            } else if anticTrigger > 0 && anticTrigger % 7 == 3 {
                modePose = squattingPose()
            } else if anticTrigger > 3 && anticTrigger % 13 == 7 {
                modePose = lyingPose()
            } else {
                modePose = idlePose()
            }
        case .listening:
            modePose = listeningPose(listenPulse)
        case .speaking:
            modePose = speakingPose(speakAmount, gesturePhase: gesturePhase,
                                    emphasisArm: emphasisArm, emphasisPhase: emphasisPhase)
        case .thinking:
            modePose = thinkingPose(thinkPhase)
        case .looking:
            modePose = lookingPose()
        }

        let emotionPose = emotionModifier(emotion)
        let emotionWeight: CGFloat = {
            switch emotion {
            case .neutral:   return 0
            case .happy:     return 0.55
            case .sad:       return 0.7
            case .surprised: return 0.85
            case .sleepy:    return 0.65
            case .shy:       return 0.6
            case .curious:   return 0.4
            case .goofy:     return 0.9
            }
        }()

        var result = blendPose(modePose, emotionPose, emotionWeight)

        // Stage walk during speaking: blend walking legs + body sway into speaking pose
        if mode == .speaking && stageWalkPhase > 0.01 {
            let stageSwing = sin(stageWalkPhase * 2 * .pi)   // -1..1
            let legSwing = stageSwing * 22                   // ±22° gentle stride
            let bodySway = stageSwing * 8                    // ±8px hip sway
            let bob = abs(stageSwing)                        // 0..1 bounce

            result.hipShiftX += bodySway
            result.neckShiftX += bodySway * 0.6
            result.headShiftY += -bob * 3
            result.bodyScale += bob * 0.04
            result.leftUpperLegAngle = deg2rad(-2 - Double(legSwing))
            result.leftLowerLegAngle = deg2rad(Double(bob * 6))
            result.rightUpperLegAngle = deg2rad(2 + Double(legSwing))
            result.rightLowerLegAngle = deg2rad(-Double(bob * 6))
        }

        if mode == .idle {
            result.headShiftY += (1 - breatheAmount) * 8
        }
        return result
    }

    // ═══════════════════════════════════════════════════════════
    //  MAIN DRAW
    // ═══════════════════════════════════════════════════════════

    static func drawStickFigure(
        in rect: CGRect,
        mode: RobotMode,
        emotion: Emotion,
        speakAmount: CGFloat,
        thinkPhase: CGFloat,
        listenPulse: CGFloat,
        breatheAmount: CGFloat,
        idleWander: CGFloat,
        blinkProgress: CGFloat,
        anticTrigger: Int,
        jumpPhase: CGFloat,
        isSpeaking: Bool,
        enginesReady: Bool = true,
        walkType: WalkType = .none,
        walkPhase: CGFloat = 0,
        stageWalkPhase: CGFloat = 0,
        gesturePhase: CGFloat = 0,
        emphasisArm: Int = -1,
        emphasisPhase: CGFloat = 0
    ) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        let w = rect.width
        let h = rect.height
        let cx = w / 2
        let figureH = h * StickGeo.figureHeightFrac
        let feetY = h * StickGeo.feetYFrac
        let headR = w * StickGeo.headRadiusFrac
        let bodyLen = h * StickGeo.bodyLengthFrac
        let shoulderHalfW = w * StickGeo.shoulderWFrac
        let hipHalfW = w * StickGeo.hipWFrac
        let upperArmLen = h * StickGeo.upperArmFrac
        let forearmLen = h * StickGeo.forearmFrac
        let upperLegLen = h * StickGeo.upperLegFrac
        let lowerLegLen = h * StickGeo.lowerLegFrac
        let eyeR = w * StickGeo.eyeRadiusFrac
        let mouthHalfW = w * StickGeo.mouthWFrac
        let jointR = StickGeo.jointRadius

        let headCY = feetY - figureH + headR

        let pose = computePose(
            mode: mode, emotion: emotion,
            speakAmount: speakAmount, thinkPhase: thinkPhase,
            listenPulse: listenPulse, breatheAmount: breatheAmount,
            anticTrigger: anticTrigger, jumpPhase: jumpPhase,
            enginesReady: enginesReady,
            walkType: walkType, walkPhase: walkPhase,
            stageWalkPhase: stageWalkPhase,
            gesturePhase: gesturePhase,
            emphasisArm: emphasisArm,
            emphasisPhase: emphasisPhase
        )

        let headCenter = CGPoint(x: cx, y: headCY)
        let neckY = headCY + headR
        let effectiveHipY = neckY + bodyLen * (1 - pose.bodyScale)

        // ═══════════════════════════════════════════════════════
        //  GROUND — drawn BEFORE any figure transforms so it
        //  stays fixed regardless of jump / rotation / etc.
        // ═══════════════════════════════════════════════════════
        drawGroundLine(ctx: ctx, cx: cx, feetY: feetY, canvasW: w)
        drawGroundShadow(ctx: ctx, cx: cx, feetY: feetY)

        // ── Auto-zoom: scale rotated figure to fill screen width comfortably ──
        let lieScale: CGFloat
        if pose.figureRotation != 0 {
            let absAngleRad = abs(pose.figureRotation) * .pi / 180
            let horizontalReach = sin(absAngleRad) * figureH + headR * 2.5
            let availableW = w / 2 - 20  // margin from edge
            if horizontalReach > availableW {
                // Scale down to fit within canvas
                lieScale = max((availableW / horizontalReach), 0.25)
            } else if horizontalReach > 0 {
                // Scale up to fill more of the screen (cap at 2.5x)
                lieScale = min((availableW / horizontalReach), 2.5)
            } else {
                lieScale = 1
            }
        } else {
            lieScale = 1
        }
        if lieScale != 1 {
            ctx.translateBy(x: cx, y: feetY)
            ctx.scaleBy(x: lieScale, y: lieScale)
            ctx.translateBy(x: -cx, y: -feetY)
        }

        // Save context for figure transforms (rotation / jump)
        ctx.saveGState()

        // Whole-body rotation (lying down) — pivot around feet so body rests on ground
        if pose.figureRotation != 0 {
            let rotCenter = CGPoint(x: cx, y: feetY)
            ctx.translateBy(x: rotCenter.x, y: rotCenter.y)
            ctx.rotate(by: pose.figureRotation * .pi / 180)
            ctx.translateBy(x: -rotCenter.x, y: -rotCenter.y)
        }

        // Jump vertical offset
        if jumpPhase > 0.01 {
            let jdy = jumpOffsetY(jumpPhase, figureH)
            if jdy != 0 {
                ctx.translateBy(x: 0, y: jdy)
            }
        }

        // ── Walk transforms ──
        switch walkType {
        case .left:
            // Walk left: wrap around screen edges (exit left → appear right)
            let cycleW = w
            let rawOffset = -walkPhase * cycleW
            let wrapped = wrapMod(rawOffset + cycleW / 2, cycleW) - cycleW / 2
            ctx.translateBy(x: wrapped, y: 0)
        case .right:
            // Walk right: wrap around screen edges (exit right → appear left)
            let cycleW = w
            let rawOffset = walkPhase * cycleW
            let wrapped = wrapMod(rawOffset + cycleW / 2, cycleW) - cycleW / 2
            ctx.translateBy(x: wrapped, y: 0)
        case .away:
            // Walk into depth: scale down, feet stay planted on ground
            let scale = 1 - walkPhase * 0.75        // 1 → 0.25
            ctx.translateBy(x: cx, y: feetY)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -cx, y: -feetY)
        case .toward:
            // Walk out of depth: scale up, feet stay planted on ground
            let scale = 0.25 + walkPhase * 0.75     // 0.25 → 1
            ctx.translateBy(x: cx, y: feetY)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -cx, y: -feetY)
        case .none: break
        }

        // ── Stage walk horizontal translation (bounded oscillation, no screen wrap) ──
        if mode == .speaking && stageWalkPhase > 0.01 {
            let amplitude = w * 0.18                    // ±18% of screen width
            let gaitPhase = stageWalkPhase * 2 * .pi
            let offset = -sin(gaitPhase) * amplitude    // shift opposite to leg stride
            ctx.translateBy(x: offset, y: 0)
        }

        // ── Joint positions ──
        let neck = CGPoint(x: cx + pose.neckShiftX, y: neckY)
        let leftShoulder  = CGPoint(x: neck.x - shoulderHalfW, y: neck.y)
        let rightShoulder = CGPoint(x: neck.x + shoulderHalfW, y: neck.y)
        let hip = CGPoint(x: cx + pose.hipShiftX, y: effectiveHipY + pose.hipShiftY)
        let leftHip  = CGPoint(x: hip.x - hipHalfW, y: hip.y)
        let rightHip = CGPoint(x: hip.x + hipHalfW, y: hip.y)

        // Start with FK angles
        var laUA = pose.leftUpperArmAngle
        var laFA = pose.leftForearmAngle
        var raUA = pose.rightUpperArmAngle
        var raFA = pose.rightForearmAngle
        var llUA = pose.leftUpperLegAngle
        var llLA = pose.leftLowerLegAngle
        var rlUA = pose.rightUpperLegAngle
        var rlLA = pose.rightLowerLegAngle

        // IK overrides
        let headForIK = CGPoint(x: headCenter.x + pose.headShiftX, y: headCenter.y + pose.headShiftY)

        if mode == .thinking {
            let chin = CGPoint(
                x: headForIK.x + headR * 0.15 + thinkPhase * 4,
                y: headForIK.y + headR * 0.6
            )
            if let ik = solve2BoneIK(root: rightShoulder, len1: upperArmLen, len2: forearmLen,
                                     target: chin, bendCCW: false) {
                raUA = ik.angle1; raFA = ik.angle2
            }
        }

        if mode == .listening {
            let ear = CGPoint(
                x: headForIK.x - headR * 0.85,
                y: headForIK.y - headR * 0.25 + listenPulse * 4
            )
            if let ik = solve2BoneIK(root: leftShoulder, len1: upperArmLen, len2: forearmLen,
                                     target: ear, bendCCW: true) {
                laUA = ik.angle1; laFA = ik.angle2
            }
        }

        // Waking up: both hands IK → eyes (rub eyes)
        if !enginesReady {
            let leftEyeTarget = CGPoint(x: headForIK.x - headR * 0.5, y: headForIK.y - headR * 0.05)
            if let ik = solve2BoneIK(root: leftShoulder, len1: upperArmLen, len2: forearmLen,
                                     target: leftEyeTarget, bendCCW: true) {
                laUA = ik.angle1; laFA = ik.angle2
            }
            let rightEyeTarget = CGPoint(x: headForIK.x + headR * 0.5, y: headForIK.y - headR * 0.05)
            if let ik = solve2BoneIK(root: rightShoulder, len1: upperArmLen, len2: forearmLen,
                                     target: rightEyeTarget, bendCCW: false) {
                raUA = ik.angle1; raFA = ik.angle2
            }
        }

        // IK for legs: lock feet on ground (all standing poses)
        // Skip during jumps (feet leave ground), lying (figure rotated), and stage walk (explicit walking angles)
        let isJumping = jumpPhase > 0.01
        let isLying = pose.figureRotation != 0
        let isStageWalk = mode == .speaking && stageWalkPhase > 0.01
        if !isJumping && !isLying && !isStageWalk {
            let isSquatting = mode == .idle && anticTrigger > 0 && anticTrigger % 7 == 3
            let footSpread: CGFloat = isSquatting ? 22 : 6
            if let ik = solve2BoneIK(root: leftHip, len1: upperLegLen, len2: lowerLegLen,
                                     target: CGPoint(x: leftHip.x - footSpread, y: feetY), bendCCW: true) {
                llUA = ik.angle1; llLA = ik.angle2
            }
            if let ik = solve2BoneIK(root: rightHip, len1: upperLegLen, len2: lowerLegLen,
                                     target: CGPoint(x: rightHip.x + footSpread, y: feetY), bendCCW: false) {
                rlUA = ik.angle1; rlLA = ik.angle2
            }
        }

        // Final limb positions
        let laOff = angleToOffset(laUA, upperArmLen)
        let leftElbow = CGPoint(x: leftShoulder.x + laOff.x, y: leftShoulder.y + laOff.y)
        let lafOff = angleToOffset(laFA, forearmLen)
        let leftHand = CGPoint(x: leftElbow.x + lafOff.x, y: leftElbow.y + lafOff.y)

        let raOff = angleToOffset(raUA, upperArmLen)
        let rightElbow = CGPoint(x: rightShoulder.x + raOff.x, y: rightShoulder.y + raOff.y)
        let rafOff = angleToOffset(raFA, forearmLen)
        let rightHand = CGPoint(x: rightElbow.x + rafOff.x, y: rightElbow.y + rafOff.y)

        let llOff = angleToOffset(llUA, upperLegLen)
        let leftKnee = CGPoint(x: leftHip.x + llOff.x, y: leftHip.y + llOff.y)
        let lllOff = angleToOffset(llLA, lowerLegLen)
        let leftFoot = CGPoint(x: leftKnee.x + lllOff.x, y: leftKnee.y + lllOff.y)

        let rlOff = angleToOffset(rlUA, upperLegLen)
        let rightKnee = CGPoint(x: rightHip.x + rlOff.x, y: rightHip.y + rlOff.y)
        let rllOff = angleToOffset(rlLA, lowerLegLen)
        let rightFoot = CGPoint(x: rightKnee.x + rllOff.x, y: rightKnee.y + rllOff.y)

        // Eye tracking
        let isThinking = mode == .thinking
        let pupilDx, pupilDy: CGFloat
        if isThinking {
            pupilDx = thinkPhase * headR * 0.15
            pupilDy = -headR * 0.55
        } else {
            let angle = CGFloat(Double(idleWander) * .pi)
            pupilDx = cos(angle) * headR * 0.08
            pupilDy = sin(angle * 1.7) * headR * 0.06
        }

        let adjustedHeadCenter = CGPoint(
            x: headCenter.x + pose.headShiftX,
            y: headCenter.y + pose.headShiftY
        )

        // ═══════════════════════════════════════════════════════
        //  DRAW ORDER (ground already drawn above transforms)
        // ═══════════════════════════════════════════════════════

        // Legs
        drawLimb(ctx: ctx, j1: leftHip, j2: leftKnee, j3: leftFoot, endR: jointR)
        drawLimb(ctx: ctx, j1: rightHip, j2: rightKnee, j3: rightFoot, endR: jointR)

        // Body
        ctx.setStrokeColor(StickColors.stickBody.cgColor)
        ctx.setLineWidth(StickGeo.bodyStroke)
        ctx.setLineCap(.round)
        ctx.move(to: neck)
        ctx.addLine(to: hip)
        ctx.strokePath()
        // Hip connectors — bridge body to leg joints
        ctx.setLineWidth(StickGeo.limbStroke)
        ctx.move(to: hip); ctx.addLine(to: leftHip); ctx.strokePath()
        ctx.move(to: hip); ctx.addLine(to: rightHip); ctx.strokePath()

        // Shoulder connectors — bridge body to arm joints
        ctx.setLineWidth(StickGeo.limbStroke)
        ctx.move(to: neck); ctx.addLine(to: leftShoulder); ctx.strokePath()
        ctx.move(to: neck); ctx.addLine(to: rightShoulder); ctx.strokePath()

        // Arms
        drawLimb(ctx: ctx, j1: leftShoulder, j2: leftElbow, j3: leftHand, endR: jointR)
        drawLimb(ctx: ctx, j1: rightShoulder, j2: rightElbow, j3: rightHand, endR: jointR)

        // Head
        drawHead(ctx: ctx, center: adjustedHeadCenter, radius: headR, emotion: emotion)

        // Face + indicators (skip for back view when walking AWAY)
        if walkType != .away {
            drawFace(ctx: ctx,
                     headCenter: adjustedHeadCenter, headRadius: headR,
                     pupilDx: pupilDx, pupilDy: pupilDy, eyeRadius: eyeR,
                     mouthHalfW: mouthHalfW, emotion: emotion,
                     isSpeaking: isSpeaking, speakAmount: speakAmount,
                     blinkAmount: blinkProgress,
                     isSideView: walkType == .left || walkType == .right,
                     facingRight: walkType == .right)

            // Mode indicators
            switch mode {
            case .listening:
                drawListenWaves(ctx: ctx, x: leftHand.x - jointR, y: leftHand.y, pulse: listenPulse)
            case .thinking:
                drawThinkDots(ctx: ctx, cx: adjustedHeadCenter.x,
                              y: adjustedHeadCenter.y - headR - 20, phase: thinkPhase)
            case .looking:
                drawLookingIndicator(ctx: ctx, cx: adjustedHeadCenter.x,
                                     y: adjustedHeadCenter.y - headR)
            default: break
            }

            // Status ring
            if mode == .thinking || mode == .speaking {
                let alpha: CGFloat = mode == .thinking ? 0.35 : 0.8
                let color = mode == .thinking ? StickColors.accent : StickColors.mouth
                ctx.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
                ctx.setLineWidth(2.5)
                let ringRect = CGRect(x: adjustedHeadCenter.x - headR - 10,
                                      y: adjustedHeadCenter.y - headR - 10,
                                      width: (headR + 10) * 2, height: (headR + 10) * 2)
                ctx.strokeEllipse(in: ringRect)
            }

            if mode == .looking {
                ctx.setStrokeColor(StickColors.lookingColor.withAlphaComponent(0.6).cgColor)
                ctx.setLineWidth(2.5)
                let ringRect = CGRect(x: adjustedHeadCenter.x - headR - 10,
                                      y: adjustedHeadCenter.y - headR - 10,
                                      width: (headR + 10) * 2, height: (headR + 10) * 2)
                ctx.strokeEllipse(in: ringRect)
            }
        }

        ctx.restoreGState()
    }

    // ═══════════════════════════════════════════════════════════
    //  DRAWING HELPERS
    // ═══════════════════════════════════════════════════════════

    private static func drawLimb(ctx: CGContext, j1: CGPoint, j2: CGPoint, j3: CGPoint, endR: CGFloat) {
        ctx.setStrokeColor(StickColors.stickBody.cgColor)
        ctx.setLineWidth(StickGeo.limbStroke)
        ctx.setLineCap(.round)
        ctx.move(to: j1); ctx.addLine(to: j2)
        ctx.strokePath()
        ctx.move(to: j2); ctx.addLine(to: j3)
        ctx.strokePath()
        // Subtle elbow/knee dot — fills the inner bend gap
        ctx.setFillColor(StickColors.stickBody.cgColor)
        ctx.fillEllipse(in: CGRect(x: j2.x - endR * 0.5, y: j2.y - endR * 0.5,
                                    width: endR * 1.0, height: endR * 1.0))
        // End dot (hand/foot)
        ctx.fillEllipse(in: CGRect(x: j3.x - endR, y: j3.y - endR,
                                    width: endR * 2, height: endR * 2))
    }

    private static func drawHead(ctx: CGContext, center: CGPoint, radius: CGFloat, emotion: Emotion) {
        // Radial gradient fill
        ctx.saveGState()
        let headRect = CGRect(x: center.x - radius, y: center.y - radius,
                              width: radius * 2, height: radius * 2)
        ctx.addEllipse(in: headRect)
        ctx.clip()
        let gradStart = CGPoint(x: center.x - radius * 0.2, y: center.y - radius * 0.35)
        ctx.drawRadialGradient(StickGradients.head,
                               startCenter: gradStart, startRadius: 0,
                               endCenter: center, endRadius: radius * 1.1, options: [])
        ctx.resetClip()

        // Outline
        ctx.setStrokeColor(StickColors.headStroke.cgColor)
        ctx.setLineWidth(2.5)
        ctx.strokeEllipse(in: headRect)

        // Blush for happy/shy — radial gradient from pink center → transparent edge
        if emotion == .happy || emotion == .shy {
            let blushR = radius * 0.22
            let blushY = center.y + radius * 0.05
            let blushXOff = radius * 0.55
            let blushColors = [
                StickColors.blush.cgColor,
                UIColor(red: 0.91, green: 0.40, blue: 0.40, alpha: 0.0).cgColor
            ] as CFArray
            let blushGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: blushColors, locations: [0, 1])!
            for sign: CGFloat in [-1, 1] {
                let c = CGPoint(x: center.x + sign * blushXOff, y: blushY)
                ctx.drawRadialGradient(blushGrad,
                                       startCenter: c, startRadius: 0,
                                       endCenter: c, endRadius: blushR,
                                       options: [])
            }
        }

        ctx.restoreGState()
    }

    // MARK: - Face

    private static func drawFace(ctx: CGContext,
                                  headCenter: CGPoint, headRadius: CGFloat,
                                  pupilDx: CGFloat, pupilDy: CGFloat,
                                  eyeRadius: CGFloat, mouthHalfW: CGFloat,
                                  emotion: Emotion, isSpeaking: Bool,
                                  speakAmount: CGFloat, blinkAmount: CGFloat,
                                  isSideView: Bool = false,
                                  facingRight: Bool = false) {
        // ── Side profile: single eye + shifted mouth ──
        if isSideView {
            let sign: CGFloat = facingRight ? 1 : -1
            let eyeXOff = headRadius * 0.3
            let eyeY = headCenter.y - headRadius * 0.12
            let sideEyeCenter = CGPoint(x: headCenter.x + sign * eyeXOff, y: eyeY)

            let lidScale: CGFloat = {
                switch emotion {
                case .sleepy: return 0.4 + blinkAmount * 0.6
                case .shy:    return 0.35 + blinkAmount * 0.65
                case .happy:  return 0.2 + blinkAmount * 0.8
                default:      return blinkAmount
                }
            }()
            if lidScale < 0.95 {
                drawEye(ctx: ctx, center: sideEyeCenter, pupilDx: pupilDx, pupilDy: pupilDy,
                        radius: eyeRadius * 1.15, lidScale: lidScale, emotion: emotion)
            }

            // Small profile mouth line on the near side
            let mouthY = headCenter.y + headRadius * 0.35
            let mouthCx = headCenter.x + sign * headRadius * 0.18
            drawMouth(ctx: ctx, cx: mouthCx, mouthY: mouthY,
                      halfWidth: mouthHalfW * 0.6, emotion: emotion,
                      isSpeaking: isSpeaking, speakAmount: speakAmount)
            return
        }

        // ── Front view: two eyes ──
        let eyeY = headCenter.y - headRadius * 0.28
        let eyeXOff = headRadius * 0.38
        let leftEyeCenter  = CGPoint(x: headCenter.x - eyeXOff, y: eyeY)
        let rightEyeCenter = CGPoint(x: headCenter.x + eyeXOff, y: eyeY)

        let lidScale: CGFloat = {
            switch emotion {
            case .sleepy: return 0.4 + blinkAmount * 0.6
            case .shy:    return 0.35 + blinkAmount * 0.65
            case .happy:  return 0.2 + blinkAmount * 0.8
            default:      return blinkAmount
            }
        }()

        if lidScale < 0.95 {
            drawEye(ctx: ctx, center: leftEyeCenter, pupilDx: pupilDx, pupilDy: pupilDy,
                    radius: eyeRadius, lidScale: lidScale, emotion: emotion)
            drawEye(ctx: ctx, center: rightEyeCenter, pupilDx: pupilDx, pupilDy: pupilDy,
                    radius: eyeRadius, lidScale: lidScale, emotion: emotion)
        }

        // Eyebrows
        let browYBase = eyeY - eyeRadius * 2.8
        let browY: CGFloat = {
            switch emotion {
            case .surprised: return browYBase - eyeRadius * 0.8
            case .goofy:     return browYBase - eyeRadius * 0.7
            default:         return browYBase
            }
        }()
        let emotionsWithBrows: Set<Emotion> = [.neutral, .sad, .surprised, .curious, .goofy, .shy]
        if emotionsWithBrows.contains(emotion) {
            let browLen = eyeRadius * 1.3
            drawEyebrow(ctx: ctx, eyeCx: leftEyeCenter.x, browY: browY,
                        halfLen: browLen, emotion: emotion, left: true)
            drawEyebrow(ctx: ctx, eyeCx: rightEyeCenter.x, browY: browY,
                        halfLen: browLen, emotion: emotion, left: false)
        }

        // Mouth
        let mouthY = headCenter.y + headRadius * 0.35
        drawMouth(ctx: ctx, cx: headCenter.x, mouthY: mouthY,
                  halfWidth: mouthHalfW, emotion: emotion,
                  isSpeaking: isSpeaking, speakAmount: speakAmount)
    }

    // MARK: - Eye

    private static func drawEye(ctx: CGContext,
                                 center: CGPoint, pupilDx: CGFloat, pupilDy: CGFloat,
                                 radius: CGFloat, lidScale: CGFloat, emotion: Emotion) {
        let pupilCenter = CGPoint(x: center.x + pupilDx, y: center.y + pupilDy)

        switch emotion {
        case .surprised:
            // Emoji 😮: wide-open round eyes with catchlights
            ctx.setFillColor(StickColors.eye.cgColor)
            ctx.fillEllipse(in: CGRect(x: pupilCenter.x - radius * 1.6, y: pupilCenter.y - radius * 1.6,
                                        width: radius * 3.2, height: radius * 3.2))
            // Large catchlight upper-left
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: pupilCenter.x - radius * 0.5, y: pupilCenter.y - radius * 0.7,
                                        width: radius * 0.45, height: radius * 0.45))

        case .happy:
            // Emoji 😊: squinted upward arcs = happy closed eyes
            let arcW = radius * 1.4
            let arcH = radius * 0.9
            let p = UIBezierPath()
            p.move(to: CGPoint(x: pupilCenter.x - arcW, y: pupilCenter.y + arcH * 0.25))
            p.addQuadCurve(to: CGPoint(x: pupilCenter.x + arcW, y: pupilCenter.y + arcH * 0.25),
                          controlPoint: CGPoint(x: pupilCenter.x, y: pupilCenter.y - arcH))
            ctx.setStrokeColor(StickColors.eye.cgColor)
            ctx.setLineWidth(3.5)
            ctx.setLineCap(.round)
            ctx.addPath(p.cgPath)
            ctx.strokePath()

        case .sleepy:
            // Emoji 😴: downward arcs = relaxed closed eyes
            let arcW = radius * 1.1
            let p = UIBezierPath()
            p.move(to: CGPoint(x: pupilCenter.x - arcW, y: pupilCenter.y - arcW * 0.15))
            p.addQuadCurve(to: CGPoint(x: pupilCenter.x + arcW, y: pupilCenter.y - arcW * 0.15),
                          controlPoint: CGPoint(x: pupilCenter.x, y: pupilCenter.y + arcW * 0.55))
            ctx.setStrokeColor(StickColors.eye.cgColor)
            ctx.setLineWidth(3.0)
            ctx.setLineCap(.round)
            ctx.addPath(p.cgPath)
            ctx.strokePath()

        case .goofy:
            // Emoji 😜: derp eyes — big circle + tiny off-center pupil
            ctx.setFillColor(StickColors.eye.cgColor)
            ctx.fillEllipse(in: CGRect(x: pupilCenter.x - radius * 1.5, y: pupilCenter.y - radius * 1.5,
                                        width: radius * 3, height: radius * 3))
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: pupilCenter.x + radius * 0.6 - radius * 0.2,
                                        y: pupilCenter.y - radius * 0.3 - radius * 0.2,
                                        width: radius * 0.4, height: radius * 0.4))
            ctx.setFillColor(StickColors.eye.cgColor)
            ctx.fillEllipse(in: CGRect(x: pupilCenter.x + radius * 0.55 - radius * 0.125,
                                        y: pupilCenter.y - radius * 0.3 - radius * 0.125,
                                        width: radius * 0.25, height: radius * 0.25))

        default:
            // Neutral/sad/shy/curious: filled circles with catchlight
            ctx.setFillColor(StickColors.eye.cgColor)
            ctx.fillEllipse(in: CGRect(x: pupilCenter.x - radius, y: pupilCenter.y - radius,
                                        width: radius * 2, height: radius * 2))
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: pupilCenter.x - radius * 0.3, y: pupilCenter.y - radius * 0.4,
                                        width: radius * 0.35, height: radius * 0.35))
        }

    }

    // MARK: - Eyebrow

    private static func drawEyebrow(ctx: CGContext, eyeCx: CGFloat, browY: CGFloat,
                                     halfLen: CGFloat, emotion: Emotion, left: Bool) {
        let p = UIBezierPath()
        let x0 = eyeCx - halfLen
        let x1 = eyeCx + halfLen
        let arch = halfLen * 0.4

        switch emotion {
        case .happy:
            break  // 😊 squint eyes carry the expression, no brows needed
        case .neutral:
            // Emoji 😐: subtle flat brows, slight downward angle toward center
            let innerY = browY + halfLen * 0.15
            p.move(to: CGPoint(x: x0, y: browY - halfLen * 0.1))
            p.addQuadCurve(to: CGPoint(x: x1, y: innerY),
                          controlPoint: CGPoint(x: eyeCx, y: browY - halfLen * 0.05))
        case .sad:
            let sign: CGFloat = left ? 1 : -1
            p.move(to: CGPoint(x: x0, y: browY + halfLen * 0.3))
            p.addQuadCurve(to: CGPoint(x: x1, y: browY - halfLen * 0.1),
                          controlPoint: CGPoint(x: eyeCx, y: browY - halfLen * 0.1 * sign))
        case .surprised:
            p.move(to: CGPoint(x: x0, y: browY - arch))
            p.addQuadCurve(to: CGPoint(x: x1, y: browY - arch),
                          controlPoint: CGPoint(x: eyeCx, y: browY - arch * 2.2))
        case .curious:
            let raise: CGFloat = left ? arch * 1.5 : 0
            p.move(to: CGPoint(x: x0, y: browY - raise))
            p.addQuadCurve(to: CGPoint(x: x1, y: browY),
                          controlPoint: CGPoint(x: eyeCx, y: browY - raise - arch * 0.5))
        case .sleepy:
            p.move(to: CGPoint(x: x0, y: browY + halfLen * 0.15))
            p.addQuadCurve(to: CGPoint(x: x1, y: browY + halfLen * 0.15),
                          controlPoint: CGPoint(x: eyeCx, y: browY + halfLen * 0.25))
        case .shy:
            p.move(to: CGPoint(x: x0, y: browY - arch * 0.3))
            p.addQuadCurve(to: CGPoint(x: x1, y: browY - arch * 0.3),
                          controlPoint: CGPoint(x: eyeCx, y: browY - arch * 1.2))
        case .goofy:
            if left {
                p.move(to: CGPoint(x: x0, y: browY - arch * 2))
                p.addQuadCurve(to: CGPoint(x: x1, y: browY - arch * 1.5),
                              controlPoint: CGPoint(x: eyeCx, y: browY - arch * 2.5))
            } else {
                p.move(to: CGPoint(x: x0, y: browY - arch * 0.3))
                p.addQuadCurve(to: CGPoint(x: x1, y: browY),
                              controlPoint: CGPoint(x: eyeCx, y: browY - arch * 1.0))
            }
        case .neutral:
            p.move(to: CGPoint(x: x0, y: browY - arch * 0.2))
            p.addQuadCurve(to: CGPoint(x: x1, y: browY - arch * 0.2),
                          controlPoint: CGPoint(x: eyeCx, y: browY - arch * 0.8))
        }

        if !p.isEmpty {
            ctx.setStrokeColor(StickColors.eye.withAlphaComponent(0.75).cgColor)
            ctx.setLineWidth(3.0)
            ctx.setLineCap(.round)
            ctx.addPath(p.cgPath)
            ctx.strokePath()
        }
    }

    // MARK: - Mouth

    private static func drawMouth(ctx: CGContext, cx: CGFloat, mouthY: CGFloat,
                                   halfWidth: CGFloat, emotion: Emotion,
                                   isSpeaking: Bool, speakAmount: CGFloat) {
        if isSpeaking {
            let rx = halfWidth * 0.8
            let baseRy = halfWidth * 0.55
            let scale: CGFloat = 0.7 + speakAmount * 0.3
            let ry = baseRy * scale

            // Mouth cavity shape (full ellipse)
            let mouthRect = CGRect(x: cx - rx, y: mouthY - ry, width: rx * 2, height: ry * 2)
            let mouthPath = UIBezierPath(ovalIn: mouthRect)

            // Dark filled mouth cavity
            ctx.setFillColor(StickColors.mouth.cgColor)
            ctx.addPath(mouthPath.cgPath)
            ctx.fillPath()

            // Clip white tooth bar to mouth shape
            ctx.saveGState()
            ctx.addPath(mouthPath.cgPath)
            ctx.clip()

            let barW = rx * 1.88
            let barH = ry * 0.84
            let barRect = CGRect(x: cx - barW / 2, y: mouthY - ry * 0.75,
                                 width: barW, height: barH)
            let barPath = UIBezierPath(roundedRect: barRect,
                                       cornerRadius: barH * 0.35)
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.addPath(barPath.cgPath)
            ctx.fillPath()

            // Tongue — also clipped to cavity
            if speakAmount > 0.5 {
                let tongueW = rx * 0.35
                let tongueH = ry * 0.5
                ctx.setFillColor(StickColors.tongue.cgColor)
                ctx.fillEllipse(in: CGRect(x: cx - tongueW, y: mouthY + ry * 0.1,
                                           width: tongueW * 2, height: tongueH * 2))
            }

            ctx.restoreGState()
            return
        }

        switch emotion {
        case .happy:
            // Emoji-style filled D-shaped open grin.
            // White head → white teeth invisible → red cavity replaces them.
            drawOpenGrin(ctx: ctx, cx: cx, mouthY: mouthY,
                         rx: halfWidth * 1.05, ry: halfWidth * 0.7)
        case .sad:
            // Emoji 😢: downturned corners, wider than neutral
            drawCurvedMouth(ctx: ctx, cx: cx, my: mouthY, hw: halfWidth * 0.85, bw: 0.85, cpY: -halfWidth * 0.45)
        case .surprised:
            // Emoji 😮: large open round mouth
            let r = halfWidth * 0.55
            ctx.setStrokeColor(StickColors.mouth.cgColor)
            ctx.setLineWidth(3.5)
            ctx.setLineCap(.round)
            ctx.strokeEllipse(in: CGRect(x: cx - r, y: mouthY - r * 0.2, width: r * 2, height: r * 1.8))
        case .curious:
            ctx.setFillColor(StickColors.mouth.cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - halfWidth * 0.35, y: mouthY - halfWidth * 0.35,
                                        width: halfWidth * 0.7, height: halfWidth * 0.7))
        case .sleepy:
            drawCurvedMouth(ctx: ctx, cx: cx, my: mouthY, hw: halfWidth * 0.65, bw: 0.65, cpY: halfWidth * 0.2)
        case .shy:
            drawCurvedMouth(ctx: ctx, cx: cx, my: mouthY, hw: halfWidth * 0.6, bw: 0.6, cpY: halfWidth * 0.15)
        case .goofy:
            // Tongue out to the side!
            let tonguePath = UIBezierPath()
            tonguePath.move(to: CGPoint(x: cx + halfWidth * 0.1, y: mouthY))
            tonguePath.addQuadCurve(to: CGPoint(x: cx + halfWidth * 0.8, y: mouthY + halfWidth * 0.6),
                                   controlPoint: CGPoint(x: cx + halfWidth * 0.5, y: mouthY + halfWidth))
            tonguePath.addQuadCurve(to: CGPoint(x: cx - halfWidth * 0.3, y: mouthY),
                                   controlPoint: CGPoint(x: cx + halfWidth * 0.6, y: mouthY + halfWidth * 0.2))
            ctx.setFillColor(StickColors.tongue.cgColor)
            ctx.addPath(tonguePath.cgPath)
            ctx.fillPath()
            // Mouth line
            let mouthLine = UIBezierPath()
            mouthLine.move(to: CGPoint(x: cx - halfWidth * 0.3, y: mouthY))
            mouthLine.addQuadCurve(to: CGPoint(x: cx + halfWidth * 0.1, y: mouthY),
                                  controlPoint: CGPoint(x: cx, y: mouthY + halfWidth * 0.3))
            ctx.setStrokeColor(StickColors.mouth.cgColor)
            ctx.setLineWidth(4)
            ctx.setLineCap(.round)
            ctx.addPath(mouthLine.cgPath)
            ctx.strokePath()
        default:
            drawCurvedMouth(ctx: ctx, cx: cx, my: mouthY, hw: halfWidth * 0.8, bw: 0.8, cpY: halfWidth * 0.08)
        }
    }

    /// Emoji-style filled semi-ellipse grin with white tooth bar clipped to cavity.
    /// - Parameters:
    ///   - rx: horizontal radius of the mouth cavity
    ///   - ry: vertical radius (depth of open mouth)
    private static func drawOpenGrin(ctx: CGContext, cx: CGFloat, mouthY: CGFloat,
                                      rx: CGFloat, ry: CGFloat) {
        // Mouth cavity shape (semi-ellipse with flat top)
        // Compensate center Y: addArc's transform scales both radius AND center.
        // `mouthY * rx / ry` cancels the `scaleX:1, y:ry/rx` transform so the
        // effective center lands back at (cx, mouthY).
        let cavityPath = CGMutablePath()
        cavityPath.addArc(center: CGPoint(x: cx, y: mouthY * rx / ry), radius: rx,
                          startAngle: 0, endAngle: .pi, clockwise: false,
                          transform: CGAffineTransform(scaleX: 1.0, y: ry / rx))
        cavityPath.closeSubpath()

        // Draw dark mouth cavity
        ctx.setFillColor(StickColors.mouth.cgColor)
        ctx.addPath(cavityPath)
        ctx.fillPath()

        // White tooth bar — clipped to cavity so it never overflows the edges
        ctx.saveGState()
        ctx.addPath(cavityPath)
        ctx.clip()

        let barW = rx * 1.88
        let barH = ry * 0.84
        let barRect = CGRect(x: cx - barW / 2, y: mouthY - barH * 0.65,
                             width: barW, height: barH)
        let barPath = UIBezierPath(roundedRect: barRect,
                                   cornerRadius: barH * 0.35)
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.addPath(barPath.cgPath)
        ctx.fillPath()

        ctx.restoreGState()
    }

    private static func drawCurvedMouth(ctx: CGContext, cx: CGFloat, my: CGFloat,
                                         hw: CGFloat, bw: CGFloat, cpY: CGFloat) {
        let x0 = cx - hw * bw
        let x1 = cx + hw * bw
        let p = UIBezierPath()
        p.move(to: CGPoint(x: x0, y: my))
        p.addQuadCurve(to: CGPoint(x: x1, y: my), controlPoint: CGPoint(x: cx, y: my + cpY))
        ctx.setStrokeColor(StickColors.mouth.cgColor)
        ctx.setLineWidth(3.5)
        ctx.setLineCap(.round)
        ctx.addPath(p.cgPath)
        ctx.strokePath()
    }

    // ═══════════════════════════════════════════════════════════
    //  INDICATORS
    // ═══════════════════════════════════════════════════════════

    private static func drawGroundShadow(ctx: CGContext, cx: CGFloat, feetY: CGFloat) {
        let shadowW: CGFloat = 50
        let shadowH: CGFloat = 8
        ctx.setFillColor(StickColors.shadow.cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - shadowW / 2, y: feetY - shadowH / 2,
                                    width: shadowW, height: shadowH))
    }

    /// Ground line across the view at foot level
    private static func drawGroundLine(ctx: CGContext, cx: CGFloat, feetY: CGFloat, canvasW: CGFloat) {
        let groundW = canvasW * 0.7
        let x0 = cx - groundW / 2
        let x1 = cx + groundW / 2
        // Subtle center-weighted line
        ctx.setStrokeColor(StickColors.stickBody.withAlphaComponent(0.1).cgColor)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: x0, y: feetY))
        ctx.addLine(to: CGPoint(x: x1, y: feetY))
        ctx.strokePath()
        // Thin shadow line just below
        ctx.setStrokeColor(StickColors.shadow.cgColor)
        ctx.setLineWidth(8)
        ctx.move(to: CGPoint(x: x0, y: feetY + 3))
        ctx.addLine(to: CGPoint(x: x1, y: feetY + 3))
        ctx.strokePath()
    }

    private static func drawListenWaves(ctx: CGContext, x: CGFloat, y: CGFloat, pulse: CGFloat) {
        for i in 0..<3 {
            let r: CGFloat = 12 + CGFloat(i) * 8 + pulse * 6
            let alpha = (1 - CGFloat(i) * 0.3) * (0.3 + pulse * 0.7)
            ctx.setStrokeColor(StickColors.accent.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: x - r, y: (y - 10) - r, width: r * 2, height: r * 2))
        }
    }

    private static func drawThinkDots(ctx: CGContext, cx: CGFloat, y: CGFloat, phase: CGFloat) {
        for i in 0..<3 {
            let dotY = y - CGFloat(i) * 16 + sin((phase + CGFloat(i) * 0.5) * .pi * 2) * 5
            let alpha: CGFloat = 0.4 + (1 - CGFloat(i) * 0.25) * 0.4
            let r: CGFloat = 4.5 - CGFloat(i) * 0.8
            ctx.setFillColor(StickColors.accent.withAlphaComponent(alpha).cgColor)
            ctx.fillEllipse(in: CGRect(x: cx + 5 - r, y: dotY - r, width: r * 2, height: r * 2))
        }
    }

    private static func drawLookingIndicator(ctx: CGContext, cx: CGFloat, y: CGFloat) {
        let bodyW: CGFloat = 14
        let bodyH: CGFloat = 10
        // Camera body
        let bodyRect = CGRect(x: cx - bodyW / 2, y: y - bodyH, width: bodyW, height: bodyH)
        let bodyPath = UIBezierPath(roundedRect: bodyRect, cornerRadius: 2)
        ctx.setFillColor(StickColors.lookingColor.withAlphaComponent(0.8).cgColor)
        ctx.addPath(bodyPath.cgPath)
        ctx.fillPath()
        // Lens
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.9).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - 3.5, y: y - bodyH / 2 - 3.5, width: 7, height: 7))
        // Flash
        ctx.setFillColor(UIColor(red: 1.0, green: 0.87, blue: 0.27, alpha: 0.6).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx + bodyW / 2 - 4, y: y - bodyH + 2 - 2, width: 4, height: 4))
    }
}

// MARK: - Utility

/// Float modulo that always returns a non-negative remainder
private func wrapMod(_ value: CGFloat, _ range: CGFloat) -> CGFloat {
    var v = value.truncatingRemainder(dividingBy: range)
    if v < 0 { v += range }
    return v
}

private func deg2rad(_ degrees: Double) -> CGFloat {
    return CGFloat(degrees * .pi / 180.0)
}
