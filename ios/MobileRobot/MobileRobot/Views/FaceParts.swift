//
//  FaceParts.swift
//  MobileRobot
//
//  Drawing functions for robot face: eyes, pupils, eyebrows, mouth, blush.
//  Ported from Android: RobotFaceScreen.kt (DrawScope extensions)
//

import Foundation
import CoreGraphics
import UIKit

// MARK: - Color Palette (iOS-friendly)

enum FaceColors {
    static let bg = UIColor(red: 0.10, green: 0.10, blue: 0.18, alpha: 1.0)
    static let faceFill = UIColor(red: 0.96, green: 0.94, blue: 0.92, alpha: 1.0)
    static let faceBorder = UIColor(red: 0.27, green: 0.27, blue: 0.47, alpha: 1.0)
    static let eyeSocket = UIColor.white
    static let pupil = UIColor(red: 0.09, green: 0.13, blue: 0.24, alpha: 1.0)
    static let iris = UIColor(red: 0.06, green: 0.20, blue: 0.38, alpha: 1.0)
    static let highlight = UIColor.white
    static let mouth = UIColor(red: 0.91, green: 0.27, blue: 0.38, alpha: 1.0)
    static let blush = UIColor(red: 0.91, green: 0.27, blue: 0.38, alpha: 0.33)
    static let eyebrow = UIColor(red: 0.18, green: 0.18, blue: 0.27, alpha: 1.0)
}

// MARK: - Geometry Constants

enum FaceGeometry {
    static let faceRadiusFraction: CGFloat = 0.40
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
    static let eyebrowYOffsetFraction: CGFloat = 0.075
    static let eyebrowLengthFraction: CGFloat = 0.14
    static let eyebrowThickness: CGFloat = 5
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

        // ── Face outline ──
        ctx.setFillColor(FaceColors.faceFill.cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - faceRadius, y: cy - faceRadius,
                                    width: faceRadius * 2, height: faceRadius * 2))
        ctx.setStrokeColor(FaceColors.faceBorder.cgColor)
        ctx.setLineWidth(4)
        ctx.strokeEllipse(in: CGRect(x: cx - faceRadius, y: cy - faceRadius,
                                      width: faceRadius * 2, height: faceRadius * 2))

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
            drawThinkingIndicator(ctx: ctx, cx: cx, y: cy - faceRadius - 20)
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

        // Eyelid
        if lidScale > 0.01 {
            let lidHeight = socketH * lidScale
            let lidTop = eyeY - socketH / 2
            ctx.setFillColor(FaceColors.faceFill.cgColor)
            ctx.fill(CGRect(x: eyeCx - socketW / 2 - 4, y: lidTop - 4,
                           width: socketW + 8, height: lidHeight + 4))
        }

        // Eye outline
        if emotion != .happy {
            ctx.setStrokeColor(FaceColors.faceBorder.cgColor)
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: socketRect)
        }
    }

    // MARK: - Eyebrow

    private static func drawEyebrow(
        ctx: CGContext, eyeCx: CGFloat, browY: CGFloat,
        halfLen: CGFloat, emotion: Emotion, left: Bool
    ) {
        ctx.setStrokeColor(FaceColors.eyebrow.cgColor)
        ctx.setLineWidth(FaceGeometry.eyebrowThickness)
        ctx.setLineCap(.round)

        let path = UIBezierPath()
        path.lineWidth = FaceGeometry.eyebrowThickness
        path.lineCapStyle = .round

        switch emotion {
        case .happy:
            path.move(to: CGPoint(x: eyeCx - halfLen, y: browY + halfLen * 0.15))
            path.addQuadCurve(to: CGPoint(x: eyeCx + halfLen, y: browY + halfLen * 0.15),
                              controlPoint: CGPoint(x: eyeCx, y: browY - halfLen * 0.5))

        case .sad:
            let sign: CGFloat = left ? -1 : 1
            let innerLow = browY + halfLen * 0.5
            path.move(to: CGPoint(x: eyeCx - halfLen * sign, y: browY - halfLen * 0.2))
            path.addLine(to: CGPoint(x: eyeCx + halfLen * sign, y: innerLow))

        case .surprised:
            path.move(to: CGPoint(x: eyeCx - halfLen, y: browY - halfLen * 0.6))
            path.addQuadCurve(to: CGPoint(x: eyeCx + halfLen, y: browY - halfLen * 0.6),
                              controlPoint: CGPoint(x: eyeCx, y: browY - halfLen * 0.8))

        case .curious:
            let raise: CGFloat = left ? halfLen * 0.5 : halfLen * 0.05
            path.move(to: CGPoint(x: eyeCx - halfLen, y: browY - raise))
            path.addQuadCurve(to: CGPoint(x: eyeCx + halfLen, y: browY - raise),
                              controlPoint: CGPoint(x: eyeCx, y: browY - raise - halfLen * 0.25))

        case .sleepy:
            path.move(to: CGPoint(x: eyeCx - halfLen, y: browY + halfLen * 0.1))
            path.addLine(to: CGPoint(x: eyeCx + halfLen, y: browY + halfLen * 0.2))

        case .shy:
            path.move(to: CGPoint(x: eyeCx - halfLen, y: browY))
            path.addQuadCurve(to: CGPoint(x: eyeCx + halfLen, y: browY),
                              controlPoint: CGPoint(x: eyeCx, y: browY - halfLen * 0.3))

        default:
            path.move(to: CGPoint(x: eyeCx - halfLen, y: browY))
            path.addQuadCurve(to: CGPoint(x: eyeCx + halfLen, y: browY),
                              controlPoint: CGPoint(x: eyeCx, y: browY - halfLen * 0.2))
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
        let speakOpen = halfWidth * 0.7 * speakAmount
        let path = UIBezierPath()

        switch emotion {
        case .happy:
            let yOff = halfWidth * 0.9 + speakOpen * 0.6
            path.move(to: CGPoint(x: cx - halfWidth * 1.2, y: mouthY))
            path.addQuadCurve(to: CGPoint(x: cx + halfWidth * 1.2, y: mouthY),
                              controlPoint: CGPoint(x: cx, y: mouthY + yOff))

        case .surprised:
            let r = halfWidth * 0.6 + speakOpen
            path.addArc(withCenter: CGPoint(x: cx, y: mouthY + r * 0.3),
                       radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: true)

        case .sad:
            path.move(to: CGPoint(x: cx - halfWidth * 0.8, y: mouthY))
            path.addQuadCurve(to: CGPoint(x: cx + halfWidth * 0.8, y: mouthY),
                              controlPoint: CGPoint(x: cx, y: mouthY - halfWidth * 0.5 - speakOpen * 0.3))

        case .curious:
            let r = halfWidth * 0.35 + speakOpen * 0.5
            ctx.setFillColor(FaceColors.mouth.cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - r, y: mouthY - r, width: r * 2, height: r * 2))
            return

        case .sleepy:
            let dy = halfWidth * 0.3 + speakOpen * 0.5
            path.move(to: CGPoint(x: cx - halfWidth * 0.5, y: mouthY))
            path.addQuadCurve(to: CGPoint(x: cx + halfWidth * 0.5, y: mouthY),
                              controlPoint: CGPoint(x: cx, y: mouthY + dy))

        case .shy:
            let dy = halfWidth * 0.15 + speakOpen * 0.3
            path.move(to: CGPoint(x: cx - halfWidth * 0.5, y: mouthY))
            path.addCurve(to: CGPoint(x: cx + halfWidth * 0.5, y: mouthY),
                          controlPoint1: CGPoint(x: cx - halfWidth * 0.25, y: mouthY - dy),
                          controlPoint2: CGPoint(x: cx + halfWidth * 0.25, y: mouthY + dy))

        default:
            let dy = halfWidth * 0.25 + speakOpen * 0.5
            path.move(to: CGPoint(x: cx - halfWidth * 0.7, y: mouthY))
            path.addQuadCurve(to: CGPoint(x: cx + halfWidth * 0.7, y: mouthY),
                              controlPoint: CGPoint(x: cx, y: mouthY + dy))
        }

        let filled = emotion == .surprised || (isSpeaking && speakAmount > 0.4)

        if filled {
            // For surprised: already drawn as filled circle above
            if emotion != .curious {
                ctx.setFillColor(FaceColors.mouth.cgColor)
                ctx.addPath(path.cgPath)
                ctx.fillPath()
            }
        } else if emotion != .curious {
            ctx.setStrokeColor(FaceColors.mouth.cgColor)
            ctx.setLineWidth(4)
            ctx.addPath(path.cgPath)
            ctx.strokePath()
        }
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
