//
//  FaceParts.swift
//  Avatar
//
//  Drawing functions for cartoon boy face in flat line-art style.
//  Thick black outlines + solid color fills — clean and simple.
//  Replaces the original robot face (ears, antenna, mechanical eyes).
//

import Foundation
import CoreGraphics
import UIKit

// MARK: - Color Palette

enum FaceColors {
    static let bg = UIColor(red: 0.10, green: 0.10, blue: 0.18, alpha: 1.0)

    /// Face fill gradient endpoints — warm skin tone
    static let faceFillLight = UIColor(red: 0.99, green: 0.94, blue: 0.88, alpha: 1.0)
    static let faceFillMid   = UIColor(red: 0.95, green: 0.88, blue: 0.80, alpha: 1.0)

    /// Thick outline — near-black for contrast
    static let faceBorder = UIColor(red: 0.12, green: 0.11, blue: 0.14, alpha: 1.0)

    /// Eyes: simple black dots
    static let eyeDot = UIColor(red: 0.10, green: 0.09, blue: 0.12, alpha: 1.0)
    static let eyeHighlight = UIColor.white

    /// Eyebrows: thick short lines
    static let eyebrow = UIColor(red: 0.12, green: 0.11, blue: 0.14, alpha: 1.0)

    /// Mouth
    static let mouth     = UIColor(red: 0.92, green: 0.42, blue: 0.45, alpha: 1.0)  // soft coral
    static let mouthOpen = UIColor(red: 0.15, green: 0.13, blue: 0.18, alpha: 1.0)  // dark inside

    /// Blush — warm peach/orange
    static let blush = UIColor(red: 0.96, green: 0.65, blue: 0.55, alpha: 0.35)

    /// Hair — near-black
    static let hairFill      = UIColor(red: 0.13, green: 0.11, blue: 0.14, alpha: 1.0)
    static let hairHighlight = UIColor(red: 0.24, green: 0.22, blue: 0.26, alpha: 1.0)

    /// Nose — subtle dark dot
    static let noseDot = UIColor(red: 0.18, green: 0.16, blue: 0.20, alpha: 0.50)

    /// T-shirt
    static let tShirtWhite = UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1.0)
    static let collarBlack = UIColor(red: 0.10, green: 0.09, blue: 0.12, alpha: 1.0)
}

// MARK: - Cached Gradients

enum FaceGradients {
    /// Radial gradient for the main face fill (warm skin).
    static let faceFill: CGGradient = {
        let colors = [FaceColors.faceFillLight.cgColor,
                      FaceColors.faceFillMid.cgColor] as CFArray
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors,
                          locations: [0.0, 1.0])!
    }()
}

// MARK: - Geometry Constants

enum FaceGeometry {
    // Face
    static let faceRadiusFraction: CGFloat   = 0.35
    static let faceCenterYFraction: CGFloat  = 0.40

    // Eyes — simple dots
    static let eyeYFraction: CGFloat          = 0.40
    static let eyeSpacingFraction: CGFloat    = 0.08
    static let eyeDotRadiusFraction: CGFloat  = 0.040

    // Highlight inside each eye
    static let eyeHlRadiusFraction: CGFloat   = 0.013
    static let eyeHlOffsetXFraction: CGFloat  = 0.010
    static let eyeHlOffsetYFraction: CGFloat  = 0.012

    // Pupil offset limits (for face tracking)
    static let pupilMaxOffsetXFraction: CGFloat = 0.06
    static let pupilMaxOffsetYFraction: CGFloat = 0.03

    // Eyebrows
    static let eyebrowYOffsetFraction: CGFloat  = 0.060
    static let eyebrowHalfLenFraction: CGFloat  = 0.10
    static let eyebrowThickness: CGFloat        = 4.5

    // Nose
    static let noseYFraction: CGFloat         = 0.475
    static let noseDotRadiusFraction: CGFloat = 0.012

    // Mouth
    static let mouthYFraction: CGFloat         = 0.560
    static let mouthHalfWidthFraction: CGFloat = 0.080

    // Blush
    static let blushYOffsetFraction: CGFloat = 0.045
    static let blushRadiusFraction: CGFloat  = 0.055

    // Hair
    static let hairRadiusExtra: CGFloat       = 0.05   // how far hair extends beyond face edge
    static let hairCapTopFraction: CGFloat    = 0.76   // where hair cap starts (0=center, 1=top of face)
    static let tuftHeightFraction: CGFloat    = 0.035  // height of hair tufts
    static let tuftWidthFraction: CGFloat     = 0.025  // half-width of tufts

    // T-shirt collar
    static let collarYFraction: CGFloat       = 0.70
    static let collarWidthFraction: CGFloat   = 0.36
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
            let dx = (targetX - 0.5) * maxOffsetX * 2
            let dy = (targetY - 0.5) * maxOffsetY * 2
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

    /// Draw the full cartoon boy face
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

        // ── Face shadow ──
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: faceRadius * 0.05),
                      blur: faceRadius * 0.10,
                      color: UIColor(white: 0, alpha: 0.30).cgColor)

        // ── Face fill with radial gradient ──
        let faceRect = CGRect(x: cx - faceRadius, y: cy - faceRadius,
                              width: faceRadius * 2, height: faceRadius * 2)
        let startPoint = CGPoint(x: cx, y: cy - faceRadius * 0.45)
        let endPoint   = CGPoint(x: cx, y: cy + faceRadius)
        ctx.addEllipse(in: faceRect)
        ctx.clip()
        ctx.drawRadialGradient(
            FaceGradients.faceFill,
            startCenter: startPoint, startRadius: faceRadius * 0.08,
            endCenter: endPoint, endRadius: faceRadius * 1.15,
            options: []
        )
        ctx.resetClip()

        // ── Face border (thick, cartoon style) ──
        ctx.setStrokeColor(FaceColors.faceBorder.cgColor)
        ctx.setLineWidth(5.5)
        ctx.strokeEllipse(in: faceRect)
        ctx.restoreGState()

        // ── Hair (on top of face) ──
        drawHair(ctx: ctx, faceCx: cx, faceCy: cy, faceRadius: faceRadius, rect: rect)

        // ── Geometry derived values ──
        let eyeY = rect.height * FaceGeometry.eyeYFraction
        let leftEyeCx  = cx - rect.width * FaceGeometry.eyeSpacingFraction
        let rightEyeCx = cx + rect.width * FaceGeometry.eyeSpacingFraction
        let eyeDotRadius = rect.width * FaceGeometry.eyeDotRadiusFraction
        let eyeHlRadius  = rect.width * FaceGeometry.eyeHlRadiusFraction
        let eyeHlOffX    = rect.width * FaceGeometry.eyeHlOffsetXFraction
        let eyeHlOffY    = rect.width * FaceGeometry.eyeHlOffsetYFraction
        let maxPupilOffsetX = rect.width * FaceGeometry.pupilMaxOffsetXFraction
        let maxPupilOffsetY = rect.width * FaceGeometry.pupilMaxOffsetYFraction
        let mouthY = rect.height * FaceGeometry.mouthYFraction
        let mouthHalfW = rect.width * FaceGeometry.mouthHalfWidthFraction
        let eyebrowHalfLen = rect.width * FaceGeometry.eyebrowHalfLenFraction
        let eyebrowYOff = rect.height * FaceGeometry.eyebrowYOffsetFraction
        let noseY = rect.height * FaceGeometry.noseYFraction
        let noseRadius = rect.width * FaceGeometry.noseDotRadiusFraction

        // Thinking: eyes look upward
        let isThinking = state.mode == .thinking
        let (pupilDx, pupilDy): (CGFloat, CGFloat)
        if isThinking {
            pupilDx = thinkPhase * maxPupilOffsetX * 0.3
            pupilDy = -maxPupilOffsetY * 0.85
        } else {
            (pupilDx, pupilDy) = computePupilOffset(
                targetX: targetX, targetY: targetY,
                hasFace: state.faceTargetX != nil, idleWander: idleWander,
                maxOffsetX: maxPupilOffsetX, maxOffsetY: maxPupilOffsetY
            )
        }

        // ── Blush ──
        if state.emotion == .happy || state.emotion == .shy {
            let blushY = eyeY + rect.height * FaceGeometry.blushYOffsetFraction
            drawBlush(ctx: ctx, cx: leftEyeCx, blushY: blushY, rect: rect)
            drawBlush(ctx: ctx, cx: rightEyeCx, blushY: blushY, rect: rect)
        }

        // ── Eyebrows ──
        let browEmotion = isThinking ? .curious : state.emotion
        drawSimpleEyebrow(ctx: ctx, eyeCx: leftEyeCx, browY: eyeY - eyebrowYOff,
                          halfLen: eyebrowHalfLen, emotion: browEmotion, left: true, rect: rect)
        drawSimpleEyebrow(ctx: ctx, eyeCx: rightEyeCx, browY: eyeY - eyebrowYOff,
                          halfLen: eyebrowHalfLen, emotion: browEmotion, left: false, rect: rect)

        // ── Eyes (dot style, blink shrinks vertically) ──
        drawDotEye(ctx: ctx, eyeCx: leftEyeCx + pupilDx, eyeY: eyeY + pupilDy,
                   dotRadius: eyeDotRadius, hlRadius: eyeHlRadius,
                   hlOffX: eyeHlOffX, hlOffY: eyeHlOffY,
                   blinkAmount: blinkProgress, emotion: state.emotion)
        drawDotEye(ctx: ctx, eyeCx: rightEyeCx + pupilDx, eyeY: eyeY + pupilDy,
                   dotRadius: eyeDotRadius, hlRadius: eyeHlRadius,
                   hlOffX: eyeHlOffX, hlOffY: eyeHlOffY,
                   blinkAmount: blinkProgress, emotion: state.emotion)

        // ── Nose ──
        drawNose(ctx: ctx, cx: cx, noseY: noseY, radius: noseRadius)

        // ── Mouth ──
        drawSimpleMouth(ctx: ctx, cx: cx, mouthY: mouthY, halfWidth: mouthHalfW,
                        emotion: state.emotion, isSpeaking: state.isSpeaking,
                        speakAmount: speakAmount)

        // ── T-shirt collar ──
        drawTShirtCollar(ctx: ctx, cx: cx, faceCy: cy, faceRadius: faceRadius, rect: rect)

        // ── Mode indicators ──
        if state.mode == .listening {
            drawListeningIndicator(ctx: ctx, cx: cx, y: cy + faceRadius + 32)
        }
        if state.mode == .thinking {
            drawThinkingIndicator(ctx: ctx, cx: cx, y: cy - faceRadius - 44)
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

    // MARK: - Hair

    /// Draws black short hair covering the upper head, with small tufts on top.
    private static func drawHair(
        ctx: CGContext, faceCx: CGFloat, faceCy: CGFloat,
        faceRadius: CGFloat, rect: CGRect
    ) {
        let hairRadius = faceRadius + rect.width * FaceGeometry.hairRadiusExtra
        let capStartAngle: CGFloat = .pi * 0.68   // left temple
        let capEndAngle: CGFloat   = .pi * 0.32   // right temple

        // ── Main hair cap (filled semi-oval on top of head) ──
        let hairPath = UIBezierPath()
        // Arc over the top of the head
        hairPath.addArc(withCenter: CGPoint(x: faceCx, y: faceCy),
                        radius: hairRadius,
                        startAngle: capStartAngle,
                        endAngle: capEndAngle,
                        clockwise: true)
        // Close along the face edge (hidden under face outline)
        hairPath.addArc(withCenter: CGPoint(x: faceCx, y: faceCy),
                        radius: faceRadius * 0.96,
                        startAngle: capEndAngle,
                        endAngle: capStartAngle,
                        clockwise: false)
        hairPath.close()

        ctx.setFillColor(FaceColors.hairFill.cgColor)
        ctx.addPath(hairPath.cgPath)
        ctx.fillPath()

        // Hair outline
        ctx.setStrokeColor(FaceColors.faceBorder.cgColor)
        ctx.setLineWidth(4.5)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(hairPath.cgPath)
        ctx.strokePath()

        // ── Hair tufts (small spikes on top) ──
        let tuftH = rect.width * FaceGeometry.tuftHeightFraction
        let tuftHW = rect.width * FaceGeometry.tuftWidthFraction
        let tuftBaseY = faceCy - hairRadius

        // 4 tufts at different positions along the top of the hair
        let tuftPositions: [CGFloat] = [-0.16, -0.05, 0.06, 0.17]  // offset from center as fraction of hairRadius
        let tuftHeights: [CGFloat]   = [1.1, 0.7, 1.0, 0.6]
        let tuftAngles: [CGFloat]    = [-0.15, -0.05, 0.05, 0.15]  // slight lean

        for i in 0..<tuftPositions.count {
            let baseX = faceCx + hairRadius * tuftPositions[i]
            let topX  = baseX + tuftHW * tuftAngles[i] * 2
            let topY  = tuftBaseY + tuftH * 2 * tuftHeights[i]

            let tuft = UIBezierPath()
            tuft.move(to: CGPoint(x: baseX - tuftHW * 0.7, y: tuftBaseY + tuftH * 0.3))
            tuft.addQuadCurve(
                to: CGPoint(x: baseX + tuftHW * 0.7, y: tuftBaseY + tuftH * 0.3),
                controlPoint: CGPoint(x: topX, y: topY)
            )
            tuft.close()

            ctx.setFillColor(FaceColors.hairFill.cgColor)
            ctx.addPath(tuft.cgPath)
            ctx.fillPath()

            // Tuft outline
            ctx.setStrokeColor(FaceColors.faceBorder.cgColor)
            ctx.setLineWidth(3.5)
            ctx.addPath(tuft.cgPath)
            ctx.strokePath()
        }

        // ── Subtle hair highlight arc ──
        let hlPath = UIBezierPath()
        hlPath.addArc(withCenter: CGPoint(x: faceCx, y: faceCy),
                      radius: hairRadius * 0.92,
                      startAngle: .pi * 0.75,
                      endAngle: .pi * 0.40,
                      clockwise: true)
        ctx.setStrokeColor(FaceColors.hairHighlight.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(1.8)
        ctx.setLineCap(.round)
        ctx.addPath(hlPath.cgPath)
        ctx.strokePath()
    }

    // MARK: - Dot Eye

    /// Draws a simple black dot eye with white highlight.
    /// Blink shrinks the dot vertically (0=open, 1=closed line).
    private static func drawDotEye(
        ctx: CGContext,
        eyeCx: CGFloat, eyeY: CGFloat,
        dotRadius: CGFloat, hlRadius: CGFloat,
        hlOffX: CGFloat, hlOffY: CGFloat,
        blinkAmount: CGFloat, emotion: Emotion
    ) {
        // Emotion tweaks to eye size
        let sizeMultiplier: CGFloat = {
            switch emotion {
            case .surprised: return 1.35
            case .sleepy:    return 0.55
            case .happy:     return 0.85
            case .shy:       return 0.80
            default:         return 1.0
            }
        }()

        let r = dotRadius * sizeMultiplier

        // Blink: vertical scale 1 (open) → 0 (closed)
        let vertScale = max(0, 1.0 - blinkAmount)
        let h = r * 2 * vertScale

        if vertScale < 0.02 { return }  // fully closed, nothing to draw

        let eyeRect: CGRect
        if emotion == .sleepy && blinkAmount < 0.3 {
            // Sleepy eyes: draw as a thin horizontal oval (not a dot)
            let sleepyW = r * 1.6
            let sleepyH = r * 0.35
            eyeRect = CGRect(x: eyeCx - sleepyW, y: eyeY - sleepyH,
                            width: sleepyW * 2, height: sleepyH * 2)
        } else if vertScale > 0.98 {
            // Nearly full open: perfect circle
            eyeRect = CGRect(x: eyeCx - r, y: eyeY - r,
                            width: r * 2, height: r * 2)
        } else {
            // Partially closed: oval that shrinks vertically
            eyeRect = CGRect(x: eyeCx - r, y: eyeY - h / 2,
                            width: r * 2, height: h)
        }

        // Eye dot
        ctx.setFillColor(FaceColors.eyeDot.cgColor)
        ctx.fillEllipse(in: eyeRect)

        // White highlight (only when mostly open)
        if vertScale > 0.5 && emotion != .sleepy {
            let hlX = eyeCx + hlOffX
            let hlY = eyeY - hlOffY
            ctx.setFillColor(FaceColors.eyeHighlight.cgColor)
            ctx.fillEllipse(in: CGRect(x: hlX - hlRadius, y: hlY - hlRadius,
                                        width: hlRadius * 2, height: hlRadius * 2))
        }
    }

    // MARK: - Simple Eyebrow

    /// Draws a short thick eyebrow line. Emotion changes the tilt and arch.
    private static func drawSimpleEyebrow(
        ctx: CGContext, eyeCx: CGFloat, browY: CGFloat,
        halfLen: CGFloat, emotion: Emotion, left: Bool, rect: CGRect
    ) {
        ctx.setStrokeColor(FaceColors.eyebrow.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(FaceGeometry.eyebrowThickness)
        ctx.setLineCap(.round)

        let x0 = eyeCx - halfLen
        let x1 = eyeCx + halfLen
        let arch = halfLen * 0.40

        let path = UIBezierPath()
        path.lineWidth = FaceGeometry.eyebrowThickness
        path.lineCapStyle = .round

        switch emotion {
        case .happy:
            // Gentle upward arch
            path.move(to: CGPoint(x: x0, y: browY))
            path.addQuadCurve(
                to: CGPoint(x: x1, y: browY),
                controlPoint: CGPoint(x: eyeCx, y: browY - arch * 1.3)
            )

        case .sad:
            // Inner ends raised (\\  /)
            let innerX = left ? x1 : x0
            let outerX = left ? x0 : x1
            path.move(to: CGPoint(x: outerX, y: browY + halfLen * 0.30))
            path.addQuadCurve(
                to: CGPoint(x: innerX, y: browY - halfLen * 0.10),
                controlPoint: CGPoint(x: eyeCx, y: browY + halfLen * 0.05)
            )

        case .surprised:
            // High raised
            let highArch = arch * 1.5
            path.move(to: CGPoint(x: x0, y: browY - highArch * 0.5))
            path.addQuadCurve(
                to: CGPoint(x: x1, y: browY - highArch * 0.5),
                controlPoint: CGPoint(x: eyeCx, y: browY - highArch * 1.2)
            )

        case .curious:
            // Asymmetric: left raised, right flatter
            let raise: CGFloat = left ? arch * 1.0 : -arch * 0.15
            path.move(to: CGPoint(x: x0, y: browY - raise * 0.6))
            path.addQuadCurve(
                to: CGPoint(x: x1, y: browY - raise * 0.1),
                controlPoint: CGPoint(x: eyeCx, y: browY - raise - arch * 0.5)
            )

        case .sleepy:
            // Drooping slightly
            path.move(to: CGPoint(x: x0, y: browY - arch * 0.2))
            path.addQuadCurve(
                to: CGPoint(x: x1, y: browY + halfLen * 0.15),
                controlPoint: CGPoint(x: eyeCx, y: browY + arch * 0.1)
            )

        case .shy:
            // Soft, slightly arched
            path.move(to: CGPoint(x: x0, y: browY - arch * 0.15))
            path.addQuadCurve(
                to: CGPoint(x: x1, y: browY - arch * 0.15),
                controlPoint: CGPoint(x: eyeCx, y: browY - arch * 0.9)
            )

        default: // neutral
            // Gentle natural arch
            path.move(to: CGPoint(x: x0, y: browY))
            path.addQuadCurve(
                to: CGPoint(x: x1, y: browY),
                controlPoint: CGPoint(x: eyeCx, y: browY - arch * 0.7)
            )
        }

        ctx.addPath(path.cgPath)
        ctx.strokePath()
    }

    // MARK: - Nose

    /// Tiny dot between eyes and mouth.
    private static func drawNose(ctx: CGContext, cx: CGFloat, noseY: CGFloat, radius: CGFloat) {
        ctx.setFillColor(FaceColors.noseDot.cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - radius, y: noseY - radius,
                                    width: radius * 2, height: radius * 1.6))
    }

    // MARK: - Blush

    private static func drawBlush(ctx: CGContext, cx: CGFloat, blushY: CGFloat, rect: CGRect) {
        let blushRadius = rect.width * FaceGeometry.blushRadiusFraction
        ctx.setFillColor(FaceColors.blush.cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - blushRadius, y: blushY - blushRadius,
                                    width: blushRadius * 2, height: blushRadius * 2))
    }

    // MARK: - Simple Mouth

    /// Cartoon simple mouth: curved smile line when closed, dark oval when open (speaking).
    private static func drawSimpleMouth(
        ctx: CGContext, cx: CGFloat, mouthY: CGFloat,
        halfWidth: CGFloat, emotion: Emotion,
        isSpeaking: Bool, speakAmount: CGFloat
    ) {
        // Surprised: small round "o"
        if emotion == .surprised {
            let r = halfWidth * (isSpeaking ? max(0.35, speakAmount) * 0.6 : 0.22)
            ctx.setFillColor(FaceColors.mouthOpen.cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - r, y: mouthY - r * 0.5,
                                       width: r * 2, height: r * 1.4))
            return
        }

        let t = isSpeaking ? speakAmount : 0

        if t > 0.08 {
            // ── Open mouth (speaking): rounded dark oval ──
            let ow = halfWidth * (0.35 + t * 0.45)
            let oh = max(halfWidth * t * 0.65, ow * 0.35)
            let rect = CGRect(x: cx - ow, y: mouthY - oh * 0.4,
                             width: ow * 2, height: oh)
            let cornerRadius = ow * 0.45
            let path = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)

            ctx.setFillColor(FaceColors.mouthOpen.cgColor)
            ctx.addPath(path.cgPath)
            ctx.fillPath()

            // Thin lip-color outline
            ctx.setStrokeColor(FaceColors.mouth.cgColor)
            ctx.setLineWidth(2.0)
            ctx.addPath(path.cgPath)
            ctx.strokePath()
        } else {
            // ── Closed mouth: simple curved smile ──
            let bw: CGFloat = {
                switch emotion {
                case .happy:     return 1.05
                case .sad:       return 0.55
                case .sleepy:    return 0.45
                case .shy:       return 0.42
                default:         return 0.65
                }
            }()

            let w = halfWidth * bw
            // Arch height and direction
            let arch: CGFloat = {
                switch emotion {
                case .happy:     return halfWidth * 0.55
                case .sad:       return -halfWidth * 0.30
                case .sleepy:    return halfWidth * 0.12
                default:         return halfWidth * 0.15
                }
            }()

            let thickness: CGFloat = halfWidth * 0.12

            let smilePath = UIBezierPath()
            smilePath.lineWidth = thickness
            smilePath.lineCapStyle = .round

            // Arc from left to right
            smilePath.move(to: CGPoint(x: cx - w, y: mouthY))
            smilePath.addQuadCurve(
                to: CGPoint(x: cx + w, y: mouthY),
                controlPoint: CGPoint(x: cx, y: mouthY + arch)
            )

            ctx.setStrokeColor(FaceColors.mouth.cgColor)
            ctx.setLineWidth(thickness)
            ctx.setLineCap(.round)
            ctx.addPath(smilePath.cgPath)
            ctx.strokePath()
        }
    }

    // MARK: - T-shirt Collar

    /// Draws a white T-shirt with a thick black collar line below the face.
    private static func drawTShirtCollar(
        ctx: CGContext, cx: CGFloat, faceCy: CGFloat,
        faceRadius: CGFloat, rect: CGRect
    ) {
        let collarY = rect.height * FaceGeometry.collarYFraction
        let collarHW = rect.width * FaceGeometry.collarWidthFraction
        let neckWidth = collarHW * 0.55

        // ── White T-shirt fill below collar ──
        let shirtPath = UIBezierPath()
        shirtPath.move(to: CGPoint(x: cx - collarHW, y: collarY))
        shirtPath.addLine(to: CGPoint(x: cx - collarHW, y: rect.height + 20))
        shirtPath.addLine(to: CGPoint(x: cx + collarHW, y: rect.height + 20))
        shirtPath.addLine(to: CGPoint(x: cx + collarHW, y: collarY))
        // Slight inward curve at the top edges (shoulder line)
        shirtPath.close()

        ctx.setFillColor(FaceColors.tShirtWhite.cgColor)
        ctx.addPath(shirtPath.cgPath)
        ctx.fillPath()

        // ── Thick black collar line (round neck) ──
        let collarPath = UIBezierPath()
        collarPath.move(to: CGPoint(x: cx - neckWidth, y: collarY + 6))
        collarPath.addQuadCurve(
            to: CGPoint(x: cx + neckWidth, y: collarY + 6),
            controlPoint: CGPoint(x: cx, y: collarY - 14)
        )

        ctx.setStrokeColor(FaceColors.collarBlack.cgColor)
        ctx.setLineWidth(5.0)
        ctx.setLineCap(.round)
        ctx.addPath(collarPath.cgPath)
        ctx.strokePath()

        // ── Shoulder outlines (thick) ──
        let shoulderLineWidth: CGFloat = 4.5
        ctx.setStrokeColor(FaceColors.collarBlack.cgColor)
        ctx.setLineWidth(shoulderLineWidth)
        ctx.setLineCap(.round)

        // Left shoulder
        ctx.move(to: CGPoint(x: cx - collarHW, y: collarY))
        ctx.addLine(to: CGPoint(x: cx - collarHW, y: collarY + 30))
        ctx.strokePath()

        // Right shoulder
        ctx.move(to: CGPoint(x: cx + collarHW, y: collarY))
        ctx.addLine(to: CGPoint(x: cx + collarHW, y: collarY + 30))
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
