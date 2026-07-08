//
//  FaceParts.swift
//  Avatar
//
//  Robot face drawing — matched to Android RobotFaceScreen.kt.
//  Antenna, oval eyes with iris/pupil/eyelid, expressive eyebrows,
//  blush, mouth with tongue, status indicators.
//

import Foundation
import CoreGraphics
import UIKit

// MARK: - Colors (matched to Android palette)

enum FaceColors {
    static let bg = UIColor(red: 0.10, green: 0.10, blue: 0.18, alpha: 1.0)          // #1A1A2E
    static let faceFillLight = UIColor(red: 0.98, green: 0.96, blue: 0.94, alpha: 1.0) // #FAF5F0
    static let faceFillMid   = UIColor(red: 0.92, green: 0.89, blue: 0.86, alpha: 1.0) // #EBE3DB
    static let faceBorder = UIColor(red: 0.27, green: 0.27, blue: 0.47, alpha: 1.0)    // #444477
    static let eyeSocket = UIColor.white
    static let pupil     = UIColor(red: 0.09, green: 0.12, blue: 0.24, alpha: 1.0)     // #16213E
    static let iris      = UIColor(red: 0.06, green: 0.20, blue: 0.38, alpha: 1.0)     // #0F3460
    static let highlight = UIColor.white
    static let mouth     = UIColor(red: 0.91, green: 0.27, blue: 0.38, alpha: 1.0)     // #E94560
    static let tongue    = UIColor(red: 1.00, green: 0.42, blue: 0.54, alpha: 1.0)     // #FF6B8A
    static let blush     = UIColor(red: 0.91, green: 0.27, blue: 0.38, alpha: 0.30)    // #E94560 30%
    static let eyebrow   = UIColor(red: 0.18, green: 0.18, blue: 0.27, alpha: 0.75)    // #2D2D44 75%

    // Robot parts
    static let antennaStroke = UIColor(red: 0.30, green: 0.30, blue: 0.50, alpha: 1.0) // #4D4D80
    static let antennaGlow   = UIColor(red: 0.40, green: 0.67, blue: 1.00, alpha: 0.80) // #66AAFF CC
}

// MARK: - Cached Gradient

enum FaceGradients {
    static let skin: CGGradient = {
        let colors = [FaceColors.faceFillLight.cgColor, FaceColors.faceFillMid.cgColor] as CFArray
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors, locations: [0, 1])!
    }()
}

// MARK: - Proportions (matched to Android Geometry Constants)

enum FaceGeo {
    // Face circle
    static let radiusFrac: CGFloat  = 0.38
    static let centerYFrac: CGFloat = 0.46

    // Eyes
    static let eyeYFrac: CGFloat          = 0.36
    static let eyeSpacingFrac: CGFloat    = 0.22
    static let socketWFrac: CGFloat       = 0.20
    static let socketHFrac: CGFloat       = 0.20
    static let pupilRFrac: CGFloat        = 0.07
    static let irisRFrac: CGFloat         = 0.09
    static let pupilMaxXFrac: CGFloat     = 0.07
    static let pupilMaxYFrac: CGFloat     = 0.04

    // Eyebrows
    static let browYOffFrac: CGFloat   = 0.078
    static let browHalfLenFrac: CGFloat = 0.14
    static let browThick: CGFloat       = 3.5

    // Blush
    static let blushBelowEyeFrac: CGFloat = 0.09  // relative to socket width

    // Mouth
    static let mouthYFrac: CGFloat     = 0.58
    static let mouthHalfWFrac: CGFloat = 0.16

    // Antenna
    static let antennaBaseYFrac: CGFloat    = 0.04
    static let antennaHeightFrac: CGFloat   = 0.10
    static let antennaBallRFrac: CGFloat    = 0.025
    static let antennaStickW: CGFloat       = 3.0
}

// MARK: - Drawer

final class FaceDrawer {

    static func computePupilOffset(
        targetX: CGFloat, targetY: CGFloat,
        hasFace: Bool, idleWander: CGFloat,
        maxX: CGFloat, maxY: CGFloat
    ) -> (CGFloat, CGFloat) {
        if hasFace {
            let dx = (targetX - 0.5) * maxX * 2
            let dy = (targetY - 0.5) * maxY * 2
            return (max(-maxX, min(maxX, dx)), max(-maxY, min(maxY, dy)))
        } else {
            let a = Double(idleWander) * .pi
            return (CGFloat(cos(a)) * maxX * 0.4, CGFloat(sin(a * 1.7)) * maxY * 0.3)
        }
    }

    // ── Main ────────────────────────────────────────────

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

        let w = rect.width
        let h = rect.height
        let cx = w * 0.5
        let cy = h * FaceGeo.centerYFrac
        let faceRadius = w * FaceGeo.radiusFrac
        let faceRect = CGRect(x: cx - faceRadius, y: cy - faceRadius,
                              width: faceRadius * 2, height: faceRadius * 2)

        // ── Face fill with radial gradient ──
        ctx.saveGState()
        ctx.addEllipse(in: faceRect)
        ctx.clip()
        ctx.drawRadialGradient(FaceGradients.skin,
                               startCenter: CGPoint(x: cx, y: cy - faceRadius * 0.5),
                               startRadius: faceRadius * 0.1,
                               endCenter: CGPoint(x: cx, y: cy + faceRadius),
                               endRadius: faceRadius * 1.2, options: [])
        ctx.resetClip()

        // Face outline
        ctx.setStrokeColor(FaceColors.faceBorder.cgColor)
        ctx.setLineWidth(4)
        ctx.strokeEllipse(in: faceRect)

        // ── Antenna ──
        drawAntenna(ctx: ctx, cx: cx, cy: cy, faceRadius: faceRadius, w: w, h: h, mode: state.mode)

        // ── Derived positions ──
        let eyeY      = h * FaceGeo.eyeYFrac
        let mouthY    = h * FaceGeo.mouthYFrac
        let leftEyeCx = cx - w * FaceGeo.eyeSpacingFrac
        let rightEyeCx = cx + w * FaceGeo.eyeSpacingFrac
        let socketW   = w * FaceGeo.socketWFrac
        let socketH   = h * FaceGeo.socketHFrac
        let pupilR    = w * FaceGeo.pupilRFrac
        let irisR     = w * FaceGeo.irisRFrac
        let maxPupilX = w * FaceGeo.pupilMaxXFrac
        let maxPupilY = w * FaceGeo.pupilMaxYFrac
        let mouthHW   = w * FaceGeo.mouthHalfWFrac
        let browHalf  = w * FaceGeo.browHalfLenFrac
        let browYOff  = w * FaceGeo.browYOffFrac

        // Pupil offset
        let isThinking = state.mode == .thinking
        let pdx, pdy: CGFloat
        if isThinking {
            pdx = thinkPhase * maxPupilX * 0.3
            pdy = -maxPupilY * 0.9
        } else {
            (pdx, pdy) = computePupilOffset(
                targetX: targetX, targetY: targetY,
                hasFace: state.faceTargetX != nil, idleWander: idleWander,
                maxX: maxPupilX, maxY: maxPupilY)
        }

        // ── Blush ──
        if state.emotion == .happy || state.emotion == .shy {
            drawBlush(ctx: ctx, cx: leftEyeCx, eyeY: eyeY, socketW: socketW)
            drawBlush(ctx: ctx, cx: rightEyeCx, eyeY: eyeY, socketW: socketW)
        }

        // ── Eyebrows ──
        let browEmotion: Emotion = isThinking ? .curious : state.emotion
        drawEyebrow(ctx: ctx, eyeCx: leftEyeCx, browY: eyeY - browYOff,
                    halfLen: browHalf, emotion: browEmotion, left: true)
        drawEyebrow(ctx: ctx, eyeCx: rightEyeCx, browY: eyeY - browYOff,
                    halfLen: browHalf, emotion: browEmotion, left: false)

        // ── Eyes ──
        drawEye(ctx: ctx, eyeCx: leftEyeCx, eyeY: eyeY,
                socketW: socketW, socketH: socketH,
                pupilDx: pdx, pupilDy: pdy,
                pupilR: pupilR, irisR: irisR,
                blink: blinkProgress, emotion: state.emotion)
        drawEye(ctx: ctx, eyeCx: rightEyeCx, eyeY: eyeY,
                socketW: socketW, socketH: socketH,
                pupilDx: pdx, pupilDy: pdy,
                pupilR: pupilR, irisR: irisR,
                blink: blinkProgress, emotion: state.emotion)

        // ── Mouth ──
        drawMouth(ctx: ctx, cx: cx, mouthY: mouthY, halfWidth: mouthHW,
                  emotion: state.emotion, isSpeaking: state.isSpeaking,
                  speakAmount: speakAmount)

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
            ctx.strokeEllipse(in: faceRect.insetBy(dx: -6, dy: -6))
        }
    }

    // MARK: - Antenna

    private static func drawAntenna(ctx: CGContext, cx: CGFloat, cy: CGFloat,
                                    faceRadius: CGFloat, w: CGFloat, h: CGFloat,
                                    mode: RobotMode) {
        let baseY  = cy - faceRadius + h * FaceGeo.antennaBaseYFrac
        let stickH = h * FaceGeo.antennaHeightFrac
        let ballR  = w * FaceGeo.antennaBallRFrac
        let tipY   = baseY - stickH
        let ballCy = tipY - ballR

        let isListening = mode == .listening
        let ballColor = isListening
            ? UIColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.7)
            : FaceColors.antennaGlow

        // Stick
        ctx.setStrokeColor(FaceColors.antennaStroke.cgColor)
        ctx.setLineWidth(FaceGeo.antennaStickW)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: cx, y: baseY))
        ctx.addLine(to: CGPoint(x: cx, y: tipY))
        ctx.strokePath()

        // Glow
        let glowR = ballR * 2.0
        let glowColors = [ballColor.withAlphaComponent(ballColor.cgColor.alpha * 0.5).cgColor,
                          ballColor.withAlphaComponent(0).cgColor] as CFArray
        if let glowGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: glowColors, locations: [0, 1]) {
            ctx.drawRadialGradient(glowGrad,
                                   startCenter: CGPoint(x: cx, y: ballCy),
                                   startRadius: 0,
                                   endCenter: CGPoint(x: cx, y: ballCy),
                                   endRadius: glowR, options: [])
        }

        // Ball
        ctx.setFillColor(ballColor.cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - ballR, y: ballCy - ballR,
                                    width: ballR * 2, height: ballR * 2))

        // Highlight
        let hlR = ballR * 0.3
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.7).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - hlR * 0.7 - hlR * 0.4,
                                    y: ballCy - hlR * 1.2 - hlR * 0.4,
                                    width: hlR * 0.8, height: hlR * 0.8))
    }

    // MARK: - Eye

    private static func drawEye(ctx: CGContext, eyeCx: CGFloat, eyeY: CGFloat,
                                socketW: CGFloat, socketH: CGFloat,
                                pupilDx: CGFloat, pupilDy: CGFloat,
                                pupilR: CGFloat, irisR: CGFloat,
                                blink: CGFloat, emotion: Emotion) {
        let socketRect = CGRect(x: eyeCx - socketW / 2, y: eyeY - socketH / 2,
                                width: socketW, height: socketH)

        let lidScale: CGFloat = {
            switch emotion {
            case .sleepy: return 0.35 + blink * 0.65
            case .shy:    return 0.30 + blink * 0.70
            case .happy:  return 0.15 + blink * 0.85
            default:      return blink
            }
        }()

        // Socket (white of eye)
        if lidScale < 0.99 {
            ctx.setFillColor(FaceColors.eyeSocket.cgColor)
            ctx.fillEllipse(in: socketRect)
        }

        // Iris
        let irisCenter = CGPoint(x: eyeCx + pupilDx * 1.5, y: eyeY + pupilDy * 1.5)
        if lidScale < 0.95 {
            ctx.setFillColor(FaceColors.iris.cgColor)
            ctx.fillEllipse(in: CGRect(x: irisCenter.x - irisR, y: irisCenter.y - irisR,
                                        width: irisR * 2, height: irisR * 2))
        }

        // Pupil
        if lidScale < 0.9 {
            ctx.setFillColor(FaceColors.pupil.cgColor)
            ctx.fillEllipse(in: CGRect(x: irisCenter.x - pupilR, y: irisCenter.y - pupilR,
                                        width: pupilR * 2, height: pupilR * 2))
        }

        // Highlight
        if lidScale < 0.85 {
            let hlOff = pupilR * 0.35
            ctx.setFillColor(FaceColors.highlight.cgColor)
            ctx.fillEllipse(in: CGRect(x: irisCenter.x - hlOff - pupilR * 0.28,
                                        y: irisCenter.y - hlOff - pupilR * 0.28,
                                        width: pupilR * 0.56, height: pupilR * 0.56))
        }

        // Eye outline
        if emotion != .happy && lidScale < 0.98 {
            ctx.setStrokeColor(FaceColors.faceBorder.cgColor)
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: socketRect)
        }

        // Eyelid — clipped to socket oval
        if lidScale > 0.01 {
            ctx.saveGState()
            ctx.addEllipse(in: socketRect)
            ctx.clip()
            let lidH = socketH * lidScale
            let lidTop = eyeY - socketH / 2
            ctx.setFillColor(FaceColors.faceFillLight.cgColor)
            ctx.fill(CGRect(x: eyeCx - socketW / 2 - 8, y: lidTop - 8,
                           width: socketW + 16, height: lidH + 8))
            ctx.restoreGState()
        }
    }

    // MARK: - Eyebrow

    private static func drawEyebrow(ctx: CGContext, eyeCx: CGFloat, browY: CGFloat,
                                    halfLen: CGFloat, emotion: Emotion, left: Bool) {
        let x0 = eyeCx - halfLen
        let x1 = eyeCx + halfLen
        let arch = halfLen * 0.35
        let p = UIBezierPath()
        p.lineWidth = FaceGeo.browThick
        p.lineCapStyle = .round

        switch emotion {
        case .happy:
            p.move(to: CGPoint(x: x0, y: browY))
            p.addCurve(to: CGPoint(x: x1, y: browY),
                       controlPoint1: CGPoint(x: x0 + halfLen * 0.4, y: browY - arch * 1.6),
                       controlPoint2: CGPoint(x: x1 - halfLen * 0.4, y: browY - arch * 1.6))
        case .sad:
            let sign: CGFloat = left ? 1 : -1
            let innerX = left ? x1 : x0
            let outerX = left ? x0 : x1
            p.move(to: CGPoint(x: outerX, y: browY + halfLen * 0.45))
            p.addCurve(to: CGPoint(x: innerX, y: browY - halfLen * 0.15),
                       controlPoint1: CGPoint(x: outerX + sign * halfLen * 0.6, y: browY + halfLen * 0.2),
                       controlPoint2: CGPoint(x: innerX - sign * halfLen * 0.6, y: browY - halfLen * 0.05))
        case .surprised:
            let highArch = arch * 1.8
            p.move(to: CGPoint(x: x0, y: browY - highArch * 0.7))
            p.addCurve(to: CGPoint(x: x1, y: browY - highArch * 0.7),
                       controlPoint1: CGPoint(x: x0 + halfLen * 0.3, y: browY - highArch * 1.1),
                       controlPoint2: CGPoint(x: x1 - halfLen * 0.3, y: browY - highArch * 1.1))
        case .curious:
            let raise: CGFloat = left ? arch * 1.3 : 0
            p.move(to: CGPoint(x: x0, y: browY - raise))
            p.addCurve(to: CGPoint(x: x1, y: browY - raise * 0.2),
                       controlPoint1: CGPoint(x: x0 + halfLen * 0.5, y: browY - raise - arch * 0.5),
                       controlPoint2: CGPoint(x: x1 - halfLen * 0.5, y: browY - raise - arch * 0.1))
        case .sleepy:
            p.move(to: CGPoint(x: x0, y: browY - arch * 0.2))
            p.addCurve(to: CGPoint(x: x1, y: browY + halfLen * 0.2),
                       controlPoint1: CGPoint(x: x0 + halfLen * 0.5, y: browY + halfLen * 0.05),
                       controlPoint2: CGPoint(x: x1 - halfLen * 0.5, y: browY + halfLen * 0.15))
        case .shy:
            p.move(to: CGPoint(x: x0, y: browY - arch * 0.3))
            p.addCurve(to: CGPoint(x: x1, y: browY - arch * 0.3),
                       controlPoint1: CGPoint(x: x0 + halfLen * 0.4, y: browY - arch * 1.0),
                       controlPoint2: CGPoint(x: x1 - halfLen * 0.4, y: browY - arch * 1.0))
        default: // neutral
            p.move(to: CGPoint(x: x0, y: browY))
            p.addCurve(to: CGPoint(x: x1, y: browY),
                       controlPoint1: CGPoint(x: x0 + halfLen * 0.4, y: browY - arch),
                       controlPoint2: CGPoint(x: x1 - halfLen * 0.4, y: browY - arch))
        }

        ctx.setStrokeColor(FaceColors.eyebrow.cgColor)
        ctx.setLineWidth(FaceGeo.browThick)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(p.cgPath)
        ctx.strokePath()
    }

    // MARK: - Blush

    private static func drawBlush(ctx: CGContext, cx: CGFloat, eyeY: CGFloat, socketW: CGFloat) {
        let blushY = eyeY + socketW * 0.9
        let r = socketW * 0.55
        ctx.setFillColor(FaceColors.blush.cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - r, y: blushY - r, width: r * 2, height: r * 2))
    }

    // MARK: - Mouth

    private static func drawMouth(ctx: CGContext, cx: CGFloat, mouthY: CGFloat,
                                  halfWidth: CGFloat, emotion: Emotion,
                                  isSpeaking: Bool, speakAmount: CGFloat) {
        // ── Speaking: outlined oval ──
        if isSpeaking {
            let rx = halfWidth * 0.7
            let baseRy = halfWidth * 0.5
            let scale: CGFloat = 0.75 + speakAmount * 0.25
            let ry = baseRy * scale
            let mr = CGRect(x: cx - rx, y: mouthY - ry, width: rx * 2, height: ry * 2)
            ctx.setStrokeColor(FaceColors.mouth.cgColor)
            ctx.setLineWidth(3.5)
            ctx.strokeEllipse(in: mr)

            // Tongue
            let tongueW = rx * 0.5
            let tongueH = ry * 0.65
            let tongueY = mouthY + ry * 0.55
            drawTongue(ctx: ctx, cx: cx, baseY: tongueY, w: tongueW, h: tongueH)
            return
        }

        // ── Closed mouth ──
        switch emotion {
        case .surprised:
            let r = halfWidth * 0.35
            let mr = CGRect(x: cx - r, y: mouthY - r * 0.7, width: r * 2, height: r * 2)
            ctx.setStrokeColor(FaceColors.mouth.cgColor)
            ctx.setLineWidth(3.5)
            ctx.strokeEllipse(in: mr)
            // Tongue
            let tongueW = r * 0.45
            let tongueH = r * 0.55
            let tongueY = mouthY + r * 0.5
            drawTongue(ctx: ctx, cx: cx, baseY: tongueY, w: tongueW, h: tongueH)
            return

        case .curious:
            ctx.setFillColor(FaceColors.mouth.cgColor)
            let r = halfWidth * 0.35
            ctx.fillEllipse(in: CGRect(x: cx - r, y: mouthY - r, width: r * 2, height: r * 2))
            return

        case .happy:
            let bw: CGFloat = 1.2
            let cpY = halfWidth * 0.9
            drawCurvedMouth(ctx: ctx, cx: cx, my: mouthY, hw: halfWidth, bw: bw, cpY: cpY)
        case .sad:
            let bw: CGFloat = 0.7
            let cpY = -halfWidth * 0.45
            drawCurvedMouth(ctx: ctx, cx: cx, my: mouthY, hw: halfWidth, bw: bw, cpY: cpY)
        case .sleepy:
            let bw: CGFloat = 0.5
            let cpY = halfWidth * 0.3
            drawCurvedMouth(ctx: ctx, cx: cx, my: mouthY, hw: halfWidth, bw: bw, cpY: cpY)
        case .shy:
            let bw: CGFloat = 0.45
            let cpY = halfWidth * 0.15
            drawCurvedMouth(ctx: ctx, cx: cx, my: mouthY, hw: halfWidth, bw: bw, cpY: cpY)
        default: // neutral
            let bw: CGFloat = 0.65
            let cpY = halfWidth * 0.12
            drawCurvedMouth(ctx: ctx, cx: cx, my: mouthY, hw: halfWidth, bw: bw, cpY: cpY)
        }
    }

    private static func drawCurvedMouth(ctx: CGContext, cx: CGFloat, my: CGFloat,
                                        hw: CGFloat, bw: CGFloat, cpY: CGFloat) {
        let x0 = cx - hw * bw
        let x1 = cx + hw * bw
        let p = UIBezierPath()
        p.move(to: CGPoint(x: x0, y: my))
        p.addQuadCurve(to: CGPoint(x: x1, y: my), controlPoint: CGPoint(x: cx, y: my + cpY))
        ctx.setStrokeColor(FaceColors.mouth.cgColor)
        ctx.setLineWidth(3.5)
        ctx.setLineCap(.round)
        ctx.addPath(p.cgPath)
        ctx.strokePath()
    }

    // MARK: - Tongue

    private static func drawTongue(ctx: CGContext, cx: CGFloat, baseY: CGFloat,
                                   w: CGFloat, h: CGFloat) {
        // Tongue body: rounded teardrop shape
        let p = UIBezierPath()
        p.move(to: CGPoint(x: cx - w, y: baseY))
        p.addCurve(to: CGPoint(x: cx, y: baseY - h),
                   controlPoint1: CGPoint(x: cx - w, y: baseY - h * 0.8),
                   controlPoint2: CGPoint(x: cx - w * 0.6, y: baseY - h))
        p.addCurve(to: CGPoint(x: cx + w, y: baseY),
                   controlPoint1: CGPoint(x: cx + w * 0.6, y: baseY - h),
                   controlPoint2: CGPoint(x: cx + w, y: baseY - h * 0.8))
        // Indent at top center
        p.addCurve(to: CGPoint(x: cx - w, y: baseY),
                   controlPoint1: CGPoint(x: cx + w * 0.3, y: baseY - h * 0.15),
                   controlPoint2: CGPoint(x: cx - w * 0.3, y: baseY - h * 0.15))
        ctx.setFillColor(FaceColors.tongue.cgColor)
        ctx.addPath(p.cgPath)
        ctx.fillPath()

        // Highlight
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.35).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - w * 0.1 - w * 0.15, y: baseY - h * 0.6 - w * 0.15,
                                    width: w * 0.3, height: w * 0.3))
    }

    // MARK: - Indicators

    private static func drawListeningIndicator(ctx: CGContext, cx: CGFloat, y: CGFloat) {
        let radii: [CGFloat] = [6, 10, 6]
        let offsets: [CGFloat] = [-20, 0, 20]
        for i in 0..<3 {
            let r = radii[i]
            let ox = offsets[i]
            ctx.setFillColor(FaceColors.mouth.withAlphaComponent(0.7).cgColor)
            ctx.fillEllipse(in: CGRect(x: cx + ox - r, y: y - r, width: r * 2, height: r * 2))
        }
    }

    private static func drawThinkingIndicator(ctx: CGContext, cx: CGFloat, y: CGFloat) {
        let r: CGFloat = 5
        let spacing: CGFloat = 14
        for i in -1...1 {
            ctx.setFillColor(FaceColors.mouth.withAlphaComponent(0.6).cgColor)
            ctx.fillEllipse(in: CGRect(x: cx + CGFloat(i) * spacing - r, y: y - r,
                                        width: r * 2, height: r * 2))
        }
    }
}
