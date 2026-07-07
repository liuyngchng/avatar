//
//  FaceParts.swift
//  MobileRobot
//
//  Drawing functions for robot face: face, ears, antenna, eyes, mouth, blush.
//  Ported from Android: RobotFaceScreen.kt (DrawScope extensions)
//

import Foundation
import CoreGraphics
import UIKit

// MARK: - Color Palette

enum FaceColors {
    static let bg = UIColor(red: 0.10, green: 0.10, blue: 0.18, alpha: 1.0)

    /// Face fill gradient endpoints
    static let faceFillLight = UIColor(red: 0.98, green: 0.96, blue: 0.94, alpha: 1.0)
    static let faceFillMid   = UIColor(red: 0.92, green: 0.89, blue: 0.86, alpha: 1.0)

    static let faceBorder = UIColor(red: 0.27, green: 0.27, blue: 0.47, alpha: 1.0)
    static let eyeSocket  = UIColor.white
    static let pupil      = UIColor(red: 0.09, green: 0.13, blue: 0.24, alpha: 1.0)
    static let iris       = UIColor(red: 0.06, green: 0.20, blue: 0.38, alpha: 1.0)
    static let highlight  = UIColor.white
    static let mouth      = UIColor(red: 0.91, green: 0.27, blue: 0.38, alpha: 1.0)
    static let blush      = UIColor(red: 0.91, green: 0.27, blue: 0.38, alpha: 0.30)
    static let eyebrow    = UIColor(red: 0.18, green: 0.18, blue: 0.27, alpha: 1.0)

    // Robot parts
    static let earFill    = UIColor(red: 0.22, green: 0.22, blue: 0.40, alpha: 1.0)
    static let earHighlight = UIColor(red: 0.4, green: 0.4, blue: 0.6, alpha: 1.0)
    static let antennaStroke = UIColor(red: 0.30, green: 0.30, blue: 0.50, alpha: 1.0)
    static let antennaGlow   = UIColor(red: 0.4, green: 0.67, blue: 1.0, alpha: 0.8)
}

// MARK: - Geometry Constants

enum FaceGeometry {
    static let faceRadiusFraction: CGFloat = 0.38
    static let faceCenterYFraction: CGFloat = 0.46
    static let eyeYFraction: CGFloat = 0.36
    static let eyeSpacingFraction: CGFloat = 0.22
    static let eyeSocketWidthFraction: CGFloat = 0.18
    static let eyeSocketHeightFraction: CGFloat = 0.24
    static let pupilRadiusFraction: CGFloat = 0.07
    static let pupilMaxOffsetXFraction: CGFloat = 0.07
    static let pupilMaxOffsetYFraction: CGFloat = 0.04
    static let irisRadiusFraction: CGFloat = 0.09
    static let mouthYFraction: CGFloat = 0.64
    static let mouthWidthFraction: CGFloat = 0.16
    static let eyebrowYOffsetFraction: CGFloat = 0.078
    static let eyebrowLengthFraction: CGFloat = 0.14
    static let eyebrowThickness: CGFloat = 3.5

    // Robot ears
    static let earWidthFraction: CGFloat = 0.09
    static let earHeightFraction: CGFloat = 0.18
    static let earOffsetXFraction: CGFloat = 0.44   // from face center
    static let earYFraction: CGFloat = 0.38

    // Antenna
    static let antennaBaseYFraction: CGFloat = 0.04  // offset from face top
    static let antennaHeightFraction: CGFloat = 0.10
    static let antennaBallRadiusFraction: CGFloat = 0.025
    static let antennaStickWidth: CGFloat = 3
}

// MARK: - Face Drawing

final class FaceDrawer {

    /// Compute pupil offset from face target position or idle wander
    static func computePupilOffset(
        targetX: CGFloat, targetY: CGFloat,
        hasFace: Bool, idleWander: CGFloat,
        maxOffsetX: CGFloat, maxOffsetY: CGFloat
    ) -> (CGFloat, CGFloat) {
        if hasFace {
            let dx = CGFloat(targetX - 0.5) * maxOffsetX * 2
            let dy = CGFloat(targetY - 0.5) * maxOffsetY * 2
            return (
                max(-maxOffsetX, min(maxOffsetX, dx)),
                max(-maxOffsetY, min(maxOffsetY, dy))
            )
        } else {
            let angle = Double(idleWander) * .pi
            return (
                CGFloat(cos(angle)) * maxOffsetX * 0.4,
                CGFloat(sin(angle * 1.7)) * maxOffsetY * 0.3
            )
        }
    }

    /// Draw the full robot face
    static func drawFace(
        in rect: CGRect,
        state: RobotState,
        targetX: CGFloat,
        targetY: CGFloat,
        idleWander: CGFloat,
        blinkProgress: CGFloat,
        speakAmount: CGFloat,
        thinkPhase: CGFloat
    ) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        let cx = rect.width / 2
        let cy = rect.height * FaceGeometry.faceCenterYFraction
        let faceRadius = rect.width * FaceGeometry.faceRadiusFraction

        // ── Robot ears ──
        drawEars(ctx: ctx, faceCx: cx, faceCy: cy, faceRadius: faceRadius, rect: rect)

        // ── Face shadow ──
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: faceRadius * 0.06),
                      blur: faceRadius * 0.12,
                      color: UIColor(white: 0, alpha: 0.35).cgColor)

        // ── Face fill with radial gradient ──
        let faceRect = CGRect(x: cx - faceRadius, y: cy - faceRadius,
                              width: faceRadius * 2, height: faceRadius * 2)
        let colors = [FaceColors.faceFillLight.cgColor,
                      FaceColors.faceFillMid.cgColor] as CFArray
        let locations: [CGFloat] = [0.0, 1.0]
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: locations
        ) {
            let startPoint = CGPoint(x: cx, y: cy - faceRadius * 0.5)
            let endPoint   = CGPoint(x: cx, y: cy + faceRadius)
            ctx.addEllipse(in: faceRect)
            ctx.clip()
            ctx.drawRadialGradient(
                gradient,
                startCenter: startPoint, startRadius: faceRadius * 0.1,
                endCenter: endPoint, endRadius: faceRadius * 1.1,
                options: []
            )
            ctx.resetClip()
        } else {
            ctx.setFillColor(FaceColors.faceFillMid.cgColor)
            ctx.fillEllipse(in: faceRect)
        }

        // ── Face border ──
        ctx.setStrokeColor(FaceColors.faceBorder.cgColor)
        ctx.setLineWidth(4)
        ctx.strokeEllipse(in: faceRect)
        ctx.restoreGState()

        // ── Antenna ──
        drawAntenna(ctx: ctx, faceCx: cx, faceCy: cy, faceRadius: faceRadius, rect: rect)

        // ── Geometry derived values ──
        let eyeY = rect.height * FaceGeometry.eyeYFraction
        let mouthY = rect.height * FaceGeometry.mouthYFraction
        let leftEyeCx = cx - rect.width * FaceGeometry.eyeSpacingFraction
        let rightEyeCx = cx + rect.width * FaceGeometry.eyeSpacingFraction
        let socketW = rect.width * FaceGeometry.eyeSocketWidthFraction
        let socketH = rect.height * FaceGeometry.eyeSocketHeightFraction
        let pupilRadius = rect.width * FaceGeometry.pupilRadiusFraction
        let irisRadius = rect.width * FaceGeometry.irisRadiusFraction
        let maxPupilOffsetX = rect.width * FaceGeometry.pupilMaxOffsetXFraction
        let maxPupilOffsetY = rect.width * FaceGeometry.pupilMaxOffsetYFraction
        let mouthHalfW = rect.width * FaceGeometry.mouthWidthFraction
        let eyebrowHalfLen = rect.width * FaceGeometry.eyebrowLengthFraction
        let eyebrowYOff = rect.width * FaceGeometry.eyebrowYOffsetFraction

        // Thinking: pupils look up
        let isThinking = state.mode == .thinking
        let (pupilDx, pupilDy): (CGFloat, CGFloat)
        if isThinking {
            pupilDx = thinkPhase * maxPupilOffsetX * 0.3
            pupilDy = -maxPupilOffsetY * 0.9
        } else {
            (pupilDx, pupilDy) = computePupilOffset(
                targetX: CGFloat(state.faceTargetX ?? 0.5), targetY: CGFloat(state.faceTargetY ?? 0.5),
                hasFace: state.faceTargetX != nil, idleWander: idleWander,
                maxOffsetX: maxPupilOffsetX, maxOffsetY: maxPupilOffsetY
            )
        }

        // ── Blush ──
        if state.emotion == .happy || state.emotion == .shy {
            drawBlush(ctx: ctx, cx: leftEyeCx, eyeY: eyeY, socketW: socketW)
            drawBlush(ctx: ctx, cx: rightEyeCx, eyeY: eyeY, socketW: socketW)
        }

        // ── Eyebrows ──
        let browEmotion = isThinking ? Emotion.curious : state.emotion
        drawEyebrow(ctx: ctx, eyeCx: leftEyeCx, browY: eyeY - eyebrowYOff,
                    halfLen: eyebrowHalfLen, emotion: browEmotion, left: true)
        drawEyebrow(ctx: ctx, eyeCx: rightEyeCx, browY: eyeY - eyebrowYOff,
                    halfLen: eyebrowHalfLen, emotion: browEmotion, left: false)

        // ── Eyes ──
        drawEye(ctx: ctx, eyeCx: leftEyeCx, eyeY: eyeY,
                socketW: socketW, socketH: socketH,
                pupilDx: pupilDx, pupilDy: pupilDy,
                pupilRadius: pupilRadius, irisRadius: irisRadius,
                blinkAmount: blinkProgress, emotion: state.emotion, faceRadius: faceRadius)
        drawEye(ctx: ctx, eyeCx: rightEyeCx, eyeY: eyeY,
                socketW: socketW, socketH: socketH,
                pupilDx: pupilDx, pupilDy: pupilDy,
                pupilRadius: pupilRadius, irisRadius: irisRadius,
                blinkAmount: blinkProgress, emotion: state.emotion, faceRadius: faceRadius)

        // ── Mouth ──
        drawMouth(ctx: ctx, cx: cx, mouthY: mouthY, halfWidth: mouthHalfW,
                  emotion: state.emotion, isSpeaking: state.isSpeaking, speakAmount: speakAmount)

        // ── Mode indicators ──
        if state.mode == .listening {
            drawListeningIndicator(ctx: ctx, cx: cx, y: cy + faceRadius + 28)
        }
        if state.mode == .thinking {
            drawThinkingIndicator(ctx: ctx, cx: cx, y: cy - faceRadius - 40)
        }

        // ── Status ring ──
        if state.mode == .thinking || state.mode == .speaking {
            let alpha: CGFloat = state.mode == .thinking ? 0.4 : 0.9
            let color = state.mode == .thinking
                ? UIColor(red: 0.4, green: 0.67, blue: 1.0, alpha: alpha)
                : FaceColors.mouth.withAlphaComponent(alpha)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: CGRect(x: cx - faceRadius - 6, y: cy - faceRadius - 6,
                                          width: (faceRadius + 6) * 2, height: (faceRadius + 6) * 2))
        }
    }

    // MARK: - Robot Ears

    private static func drawEars(
        ctx: CGContext, faceCx: CGFloat, faceCy: CGFloat,
        faceRadius: CGFloat, rect: CGRect
    ) {
        let earW = rect.width * FaceGeometry.earWidthFraction
        let earH = rect.height * FaceGeometry.earHeightFraction
        let earOffX = rect.width * FaceGeometry.earOffsetXFraction
        let earY = rect.height * FaceGeometry.earYFraction

        let earCornerRadius = earW * 0.45

        for side: CGFloat in [-1, 1] {
            let earCx = faceCx + earOffX * side
            let earRect = CGRect(x: earCx - earW / 2, y: earY - earH / 2,
                                 width: earW, height: earH)

            let path = UIBezierPath(roundedRect: earRect, cornerRadius: earCornerRadius)
            ctx.addPath(path.cgPath)

            // Ear fill with gradient
            ctx.saveGState()
            ctx.addPath(path.cgPath)
            ctx.clip()

            let colors = [FaceColors.earHighlight.cgColor,
                          FaceColors.earFill.cgColor] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0.0, 1.0]
            ) {
                ctx.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: earCx, y: earY - earH / 2),
                    end: CGPoint(x: earCx, y: earY + earH / 2),
                    options: []
                )
            }
            ctx.restoreGState()

            // Ear border
            ctx.setStrokeColor(FaceColors.faceBorder.cgColor)
            ctx.setLineWidth(2.5)
            ctx.addPath(path.cgPath)
            ctx.strokePath()
        }
    }

    // MARK: - Antenna

    private static func drawAntenna(
        ctx: CGContext, faceCx: CGFloat, faceCy: CGFloat,
        faceRadius: CGFloat, rect: CGRect
    ) {
        let baseY = faceCy - faceRadius + rect.height * FaceGeometry.antennaBaseYFraction
        let stickHeight = rect.height * FaceGeometry.antennaHeightFraction
        let ballRadius = rect.width * FaceGeometry.antennaBallRadiusFraction
        let tipY = baseY - stickHeight
        let ballCy = tipY - ballRadius

        // Stick
        ctx.setStrokeColor(FaceColors.antennaStroke.cgColor)
        ctx.setLineWidth(FaceGeometry.antennaStickWidth)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: faceCx, y: baseY))
        ctx.addLine(to: CGPoint(x: faceCx, y: tipY))
        ctx.strokePath()

        // Glow ball
        ctx.saveGState()
        let glowRadius = ballRadius * 2.0
        let glowColors = [FaceColors.antennaGlow.withAlphaComponent(0.5).cgColor,
                          FaceColors.antennaGlow.withAlphaComponent(0.0).cgColor] as CFArray
        if let glowGrad = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: glowColors,
            locations: [0.0, 1.0]
        ) {
            ctx.drawRadialGradient(
                glowGrad,
                startCenter: CGPoint(x: faceCx, y: ballCy),
                startRadius: ballRadius * 0.5,
                endCenter: CGPoint(x: faceCx, y: ballCy),
                endRadius: glowRadius,
                options: []
            )
        }
        ctx.restoreGState()

        // Ball
        ctx.setFillColor(FaceColors.antennaGlow.cgColor)
        ctx.fillEllipse(in: CGRect(x: faceCx - ballRadius, y: ballCy - ballRadius,
                                   width: ballRadius * 2, height: ballRadius * 2))

        // Ball highlight
        let hlR = ballRadius * 0.3
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.7).cgColor)
        ctx.fillEllipse(in: CGRect(x: faceCx - hlR * 0.7, y: ballCy - hlR * 1.2,
                                   width: hlR * 0.8, height: hlR * 0.8))
    }

    // MARK: - Eye

    private static func drawEye(
        ctx: CGContext,
        eyeCx: CGFloat, eyeY: CGFloat,
        socketW: CGFloat, socketH: CGFloat,
        pupilDx: CGFloat, pupilDy: CGFloat,
        pupilRadius: CGFloat, irisRadius: CGFloat,
        blinkAmount: CGFloat, emotion: Emotion, faceRadius: CGFloat
    ) {
        let lidScale: CGFloat = {
            switch emotion {
            case .sleepy: return 0.35 + blinkAmount * 0.65
            case .shy:    return 0.30 + blinkAmount * 0.70
            case .happy:  return 0.15 + blinkAmount * 0.85
            default:      return blinkAmount
            }
        }()

        let socketRect = CGRect(x: eyeCx - socketW / 2, y: eyeY - socketH / 2,
                                width: socketW, height: socketH)

        // Socket
        if lidScale < 0.99 {
            ctx.setFillColor(FaceColors.eyeSocket.cgColor)
            ctx.fillEllipse(in: socketRect)
        }

        // Iris
        let irisCenter = CGPoint(x: eyeCx + pupilDx * 1.5, y: eyeY + pupilDy * 1.5)
        if lidScale < 0.95 {
            ctx.setFillColor(FaceColors.iris.cgColor)
            ctx.fillEllipse(in: CGRect(x: irisCenter.x - irisRadius, y: irisCenter.y - irisRadius,
                                        width: irisRadius * 2, height: irisRadius * 2))
        }

        // Pupil
        if lidScale < 0.9 {
            ctx.setFillColor(FaceColors.pupil.cgColor)
            ctx.fillEllipse(in: CGRect(x: irisCenter.x - pupilRadius, y: irisCenter.y - pupilRadius,
                                        width: pupilRadius * 2, height: pupilRadius * 2))
        }

        // Highlight
        if lidScale < 0.85 {
            let hlOffset = pupilRadius * 0.35
            ctx.setFillColor(FaceColors.highlight.cgColor)
            ctx.fillEllipse(in: CGRect(x: irisCenter.x - hlOffset - pupilRadius * 0.28,
                                        y: irisCenter.y - hlOffset - pupilRadius * 0.28,
                                        width: pupilRadius * 0.56, height: pupilRadius * 0.56))
        }

        // Eye outline — drawn before eyelid so the lid covers it when blinking.
        // Happy eyes look softer without outline (perpetual squint).
        if emotion != .happy && lidScale < 0.98 {
            ctx.setStrokeColor(FaceColors.faceBorder.cgColor)
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: socketRect)
        }

        // Eyelid — clipped to socket ellipse so it follows the eye contour
        if lidScale > 0.01 {
            ctx.saveGState()
            ctx.addEllipse(in: socketRect)
            ctx.clip()
            let lidHeight = socketH * lidScale
            let lidTop = eyeY - socketH / 2
            ctx.setFillColor(FaceColors.faceFillLight.cgColor)
            ctx.fill(CGRect(x: eyeCx - socketW / 2 - 8, y: lidTop - 8,
                           width: socketW + 16, height: lidHeight + 8))
            ctx.restoreGState()
        }
    }

    // MARK: - Eyebrow

    private static func drawEyebrow(
        ctx: CGContext, eyeCx: CGFloat, browY: CGFloat,
        halfLen: CGFloat, emotion: Emotion, left: Bool
    ) {
        ctx.setStrokeColor(FaceColors.eyebrow.withAlphaComponent(0.75).cgColor)
        ctx.setLineWidth(FaceGeometry.eyebrowThickness)
        ctx.setLineCap(.round)

        let path = UIBezierPath()
        path.lineWidth = FaceGeometry.eyebrowThickness
        path.lineCapStyle = .round

        let x0 = eyeCx - halfLen
        let x1 = eyeCx + halfLen
        let arch = halfLen * 0.35  // natural arch height

        switch emotion {
        case .happy:
            // Gentle upward arc, happy
            path.move(to: CGPoint(x: x0, y: browY))
            path.addCurve(to: CGPoint(x: x1, y: browY),
                          controlPoint1: CGPoint(x: x0 + halfLen * 0.4, y: browY - arch * 1.6),
                          controlPoint2: CGPoint(x: x1 - halfLen * 0.4, y: browY - arch * 1.6))

        case .sad:
            // Inner ends raised, outer ends down
            let sign: CGFloat = left ? 1 : -1
            let innerX = left ? x1 : x0
            let outerX = left ? x0 : x1
            path.move(to: CGPoint(x: outerX, y: browY + halfLen * 0.45))
            path.addCurve(to: CGPoint(x: innerX, y: browY - halfLen * 0.15),
                          controlPoint1: CGPoint(x: outerX + sign * halfLen * 0.6, y: browY + halfLen * 0.2),
                          controlPoint2: CGPoint(x: innerX - sign * halfLen * 0.6, y: browY - halfLen * 0.05))

        case .surprised:
            // High raised arches
            let highArch = arch * 1.8
            path.move(to: CGPoint(x: x0, y: browY - highArch * 0.7))
            path.addCurve(to: CGPoint(x: x1, y: browY - highArch * 0.7),
                          controlPoint1: CGPoint(x: x0 + halfLen * 0.3, y: browY - highArch * 1.1),
                          controlPoint2: CGPoint(x: x1 - halfLen * 0.3, y: browY - highArch * 1.1))

        case .curious:
            // One raised (left), one flat
            let raise: CGFloat = left ? arch * 1.3 : 0
            path.move(to: CGPoint(x: x0, y: browY - raise))
            path.addCurve(to: CGPoint(x: x1, y: browY - raise * 0.2),
                          controlPoint1: CGPoint(x: x0 + halfLen * 0.5, y: browY - raise - arch * 0.5),
                          controlPoint2: CGPoint(x: x1 - halfLen * 0.5, y: browY - raise - arch * 0.1))

        case .sleepy:
            // Drooping downward toward outer edges
            path.move(to: CGPoint(x: x0, y: browY - arch * 0.2))
            path.addCurve(to: CGPoint(x: x1, y: browY + halfLen * 0.2),
                          controlPoint1: CGPoint(x: x0 + halfLen * 0.5, y: browY + halfLen * 0.05),
                          controlPoint2: CGPoint(x: x1 - halfLen * 0.5, y: browY + halfLen * 0.15))

        case .shy:
            // Slightly raised, soft
            path.move(to: CGPoint(x: x0, y: browY - arch * 0.3))
            path.addCurve(to: CGPoint(x: x1, y: browY - arch * 0.3),
                          controlPoint1: CGPoint(x: x0 + halfLen * 0.4, y: browY - arch * 1.0),
                          controlPoint2: CGPoint(x: x1 - halfLen * 0.4, y: browY - arch * 1.0))

        default:
            // Neutral: gentle natural arch
            path.move(to: CGPoint(x: x0, y: browY))
            path.addCurve(to: CGPoint(x: x1, y: browY),
                          controlPoint1: CGPoint(x: x0 + halfLen * 0.4, y: browY - arch),
                          controlPoint2: CGPoint(x: x1 - halfLen * 0.4, y: browY - arch))
        }

        ctx.addPath(path.cgPath)
        ctx.strokePath()
    }

    // MARK: - Blush

    private static func drawBlush(ctx: CGContext, cx: CGFloat, eyeY: CGFloat, socketW: CGFloat) {
        let blushCx = cx
        let blushY = eyeY + socketW * 0.6
        let blushRadius = socketW * 0.55
        ctx.setFillColor(FaceColors.blush.cgColor)
        ctx.fillEllipse(in: CGRect(x: blushCx - blushRadius, y: blushY - blushRadius,
                                    width: blushRadius * 2, height: blushRadius * 2))
    }

    // MARK: - Mouth

    private static func drawMouth(
        ctx: CGContext, cx: CGFloat, mouthY: CGFloat,
        halfWidth: CGFloat, emotion: Emotion,
        isSpeaking: Bool, speakAmount: CGFloat
    ) {
        // speakAmount 0..1: 0 = closed, 1 = fully open
        let openRatio = isSpeaking ? speakAmount : 0

        // ── Open mouth (speaking): draw as a filled ellipse ──────────
        if openRatio > 0.15 {
            let openW = halfWidth * 0.5 * openRatio
            let openH = halfWidth * 0.85 * openRatio
            let ovalRect = CGRect(x: cx - openW, y: mouthY - openH * 0.5,
                                  width: openW * 2, height: openH * 1.6)

            // Outer lip
            ctx.setFillColor(FaceColors.mouth.cgColor)
            ctx.fillEllipse(in: ovalRect)

            // Inner dark (depth)
            let innerW = openW * 0.55
            let innerH = openH * 0.5
            ctx.setFillColor(FaceColors.pupil.withAlphaComponent(0.6).cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - innerW, y: mouthY + innerH * 0.3,
                                       width: innerW * 2, height: innerH * 1.4))
            return
        }

        // ── Closed mouth: thin curved line ───────────────────────────
        let path = UIBezierPath()
        let bw: CGFloat   // width multiplier
        let cpY: CGFloat  // control point y offset (positive = smile, negative = frown)

        switch emotion {
        case .happy:
            bw = 1.2
            cpY = halfWidth * 0.9
        case .sad:
            bw = 0.7
            cpY = -halfWidth * 0.45
        case .surprised:
            // Small round "o"
            let r = halfWidth * 0.35
            ctx.setStrokeColor(FaceColors.mouth.cgColor)
            ctx.setLineWidth(3.5)
            ctx.strokeEllipse(in: CGRect(x: cx - r, y: mouthY - r * 0.7,
                                         width: r * 2, height: r * 2))
            return
        case .curious:
            let r = halfWidth * 0.35
            ctx.setFillColor(FaceColors.mouth.cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - r, y: mouthY - r, width: r * 2, height: r * 2))
            return
        case .sleepy:
            bw = 0.5
            cpY = halfWidth * 0.3
        case .shy:
            bw = 0.45
            cpY = halfWidth * 0.15
        default:
            bw = 0.65
            cpY = halfWidth * 0.12  // subtle, almost flat
        }

        let x0 = cx - halfWidth * bw
        let x1 = cx + halfWidth * bw
        path.move(to: CGPoint(x: x0, y: mouthY))
        path.addQuadCurve(to: CGPoint(x: x1, y: mouthY),
                          controlPoint: CGPoint(x: cx, y: mouthY + cpY))

        ctx.setStrokeColor(FaceColors.mouth.cgColor)
        ctx.setLineWidth(3.5)
        ctx.setLineCap(.round)
        ctx.addPath(path.cgPath)
        ctx.strokePath()
    }

    // MARK: - Indicators

    private static func drawListeningIndicator(ctx: CGContext, cx: CGFloat, y: CGFloat) {
        let radii: [CGFloat] = [6, 10, 6]
        let offsets: [CGFloat] = [-20, 0, 20]
        let color = FaceColors.mouth.withAlphaComponent(0.7)
        ctx.setFillColor(color.cgColor)
        for i in 0..<radii.count {
            ctx.fillEllipse(in: CGRect(x: cx + offsets[i] - radii[i], y: y - radii[i],
                                        width: radii[i] * 2, height: radii[i] * 2))
        }
    }

    private static func drawThinkingIndicator(ctx: CGContext, cx: CGFloat, y: CGFloat) {
        let dotRadius: CGFloat = 5
        let spacing: CGFloat = 14
        let color = FaceColors.mouth.withAlphaComponent(0.6)
        ctx.setFillColor(color.cgColor)
        for i in -1...1 {
            ctx.fillEllipse(in: CGRect(x: cx + CGFloat(i) * spacing - dotRadius,
                                        y: y - dotRadius,
                                        width: dotRadius * 2, height: dotRadius * 2))
        }
    }
}
