//
//  FaceParts.swift
//  Avatar
//
//  Simple cartoon face — clean, cute, hand-drawn style.
//  Round face, dot eyes, curved smile, simple hair.
//

import Foundation
import CoreGraphics
import UIKit

// MARK: - Colors

enum FaceColors {
    static let bg = UIColor(red: 0.10, green: 0.10, blue: 0.18, alpha: 1.0)

    // Skin
    static let skinLight = UIColor(red: 1.00, green: 0.95, blue: 0.90, alpha: 1.0)
    static let skinMid   = UIColor(red: 0.96, green: 0.89, blue: 0.82, alpha: 1.0)

    // Outline
    static let outline = UIColor(red: 0.10, green: 0.09, blue: 0.12, alpha: 1.0)

    // Features
    static let eye       = UIColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
    static let eyeLight  = UIColor.white
    static let brow      = UIColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
    static let mouth     = UIColor(red: 0.92, green: 0.45, blue: 0.45, alpha: 1.0)
    static let mouthDark = UIColor(red: 0.12, green: 0.10, blue: 0.14, alpha: 1.0)
    static let blush     = UIColor(red: 0.98, green: 0.68, blue: 0.60, alpha: 0.33)
    static let nose      = UIColor(red: 0.16, green: 0.14, blue: 0.18, alpha: 0.40)

    // Hair
    static let hair      = UIColor(red: 0.10, green: 0.09, blue: 0.12, alpha: 1.0)
}

// MARK: - Cached Gradient

enum FaceGradients {
    static let skin: CGGradient = {
        let colors = [FaceColors.skinLight.cgColor, FaceColors.skinMid.cgColor] as CFArray
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors, locations: [0, 1])!
    }()
}

// MARK: - Proportions

enum FaceGeo {
    // Face circle
    static let radiusFrac: CGFloat  = 0.36
    static let centerYFrac: CGFloat = 0.46

    // Eyes
    static let eyeYFrac: CGFloat       = 0.405
    static let eyeGapFrac: CGFloat     = 0.085    // from center to eye center
    static let eyeDotRFrac: CGFloat    = 0.052
    static let eyeHlRFrac: CGFloat     = 0.016
    static let eyeHlOffXFrac: CGFloat  = 0.013
    static let eyeHlOffYFrac: CGFloat  = 0.016

    // Pupil travel
    static let pupilMaxXFrac: CGFloat = 0.05
    static let pupilMaxYFrac: CGFloat = 0.025

    // Eyebrows
    static let browAboveEyeFrac: CGFloat = 0.048
    static let browHalfLenFrac: CGFloat  = 0.095
    static let browThick: CGFloat        = 5.0

    // Nose
    static let noseYFrac: CGFloat = 0.48
    static let noseRFrac: CGFloat = 0.010

    // Mouth
    static let mouthYFrac: CGFloat    = 0.565
    static let mouthHalfWFrac: CGFloat = 0.075

    // Blush
    static let blushBelowEyeFrac: CGFloat = 0.040
    static let blushRFrac: CGFloat        = 0.050

    // Hair
    static let hairExtraFrac: CGFloat  = 0.045  // how far beyond face
    static let tuftHFrac: CGFloat      = 0.032
    static let tuftHWFrac: CGFloat     = 0.022
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
            return (CGFloat(cos(a)) * maxX * 0.35, CGFloat(sin(a * 1.7)) * maxY * 0.25)
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
        let r  = w * FaceGeo.radiusFrac
        let cx = w * 0.5
        let cy = h * FaceGeo.centerYFrac
        let faceRect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)

        // ── Shadow ──
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: r * 0.04),
                      blur: r * 0.08, color: UIColor(white: 0, alpha: 0.22).cgColor)

        // ── Face fill ──
        ctx.addEllipse(in: faceRect)
        ctx.clip()
        ctx.drawRadialGradient(FaceGradients.skin,
                               startCenter: CGPoint(x: cx, y: cy - r * 0.45),
                               startRadius: r * 0.08,
                               endCenter: CGPoint(x: cx, y: cy + r),
                               endRadius: r * 1.2, options: [])
        ctx.resetClip()

        // ── Face outline ──
        ctx.setStrokeColor(FaceColors.outline.cgColor)
        ctx.setLineWidth(5)
        ctx.strokeEllipse(in: faceRect)
        ctx.restoreGState()

        // ── Hair ──
        drawHair(ctx: ctx, cx: cx, cy: cy, r: r, w: w)

        // ── Derived positions ──
        let eyeY    = h * FaceGeo.eyeYFrac
        let eyeGap  = w * FaceGeo.eyeGapFrac
        let leftEx  = cx - eyeGap
        let rightEx = cx + eyeGap
        let dotR    = w * FaceGeo.eyeDotRFrac
        let hlR     = w * FaceGeo.eyeHlRFrac
        let hlOx    = w * FaceGeo.eyeHlOffXFrac
        let hlOy    = w * FaceGeo.eyeHlOffYFrac
        let maxPx   = w * FaceGeo.pupilMaxXFrac
        let maxPy   = w * FaceGeo.pupilMaxYFrac
        let browLen = w * FaceGeo.browHalfLenFrac
        let browOff = h * FaceGeo.browAboveEyeFrac
        let noseY   = h * FaceGeo.noseYFrac
        let noseR   = w * FaceGeo.noseRFrac
        let mouthY  = h * FaceGeo.mouthYFrac
        let mouthHW = w * FaceGeo.mouthHalfWFrac

        // Pupil offset
        let isThink = state.mode == .thinking
        let pdx, pdy: CGFloat
        if isThink {
            pdx = thinkPhase * maxPx * 0.3
            pdy = -maxPy * 0.8
        } else {
            (pdx, pdy) = computePupilOffset(
                targetX: targetX, targetY: targetY,
                hasFace: state.faceTargetX != nil, idleWander: idleWander,
                maxX: maxPx, maxY: maxPy)
        }

        // ── Blush ──
        if state.emotion == .happy || state.emotion == .shy {
            let by = eyeY + h * FaceGeo.blushBelowEyeFrac
            let br = w * FaceGeo.blushRFrac
            drawBlush(ctx: ctx, cx: leftEx + br * 0.3, cy: by, r: br)
            drawBlush(ctx: ctx, cx: rightEx - br * 0.3, cy: by, r: br)
        }

        // ── Eyebrows ──
        let bEmo = isThink ? .curious : state.emotion
        drawBrow(ctx: ctx, cx: leftEx, top: eyeY - browOff, half: browLen, emo: bEmo, left: true)
        drawBrow(ctx: ctx, cx: rightEx, top: eyeY - browOff, half: browLen, emo: bEmo, left: false)

        // ── Eyes ──
        drawEye(ctx: ctx, cx: leftEx + pdx, cy: eyeY + pdy,
                r: dotR, hlR: hlR, hlOx: hlOx, hlOy: hlOy,
                blink: blinkProgress, emo: state.emotion)
        drawEye(ctx: ctx, cx: rightEx + pdx, cy: eyeY + pdy,
                r: dotR, hlR: hlR, hlOx: hlOx, hlOy: hlOy,
                blink: blinkProgress, emo: state.emotion)

        // ── Nose ──
        drawNose(ctx: ctx, cx: cx, cy: noseY, r: noseR)

        // ── Mouth ──
        drawMouth(ctx: ctx, cx: cx, cy: mouthY, hw: mouthHW,
                  emo: state.emotion, speaking: state.isSpeaking, t: speakAmount)

        // ── Indicators ──
        if state.mode == .listening {
            drawListen(ctx: ctx, cx: cx, y: cy + r + 28)
        }
        if state.mode == .thinking {
            drawThink(ctx: ctx, cx: cx, y: cy - r - 38)
        }

        // ── Status ring ──
        if state.mode == .thinking || state.mode == .speaking {
            let a: CGFloat = state.mode == .thinking ? 0.4 : 0.85
            let color = state.mode == .thinking
                ? UIColor(red: 0.4, green: 0.67, blue: 1.0, alpha: a)
                : FaceColors.mouth.withAlphaComponent(a)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: faceRect.insetBy(dx: -8, dy: -8))
        }
    }

    // MARK: - Hair

    private static func drawHair(ctx: CGContext, cx: CGFloat, cy: CGFloat,
                                  r: CGFloat, w: CGFloat) {
        let hr = r + w * FaceGeo.hairExtraFrac

        // Dome
        let dome = UIBezierPath()
        dome.addArc(withCenter: CGPoint(x: cx, y: cy), radius: hr,
                    startAngle: .pi * 0.70, endAngle: .pi * 0.30, clockwise: true)
        // Close along face
        dome.addArc(withCenter: CGPoint(x: cx, y: cy), radius: r * 0.94,
                    startAngle: .pi * 0.30, endAngle: .pi * 0.70, clockwise: false)
        dome.close()
        ctx.setFillColor(FaceColors.hair.cgColor)
        ctx.addPath(dome.cgPath)
        ctx.fillPath()
        ctx.setStrokeColor(FaceColors.outline.cgColor)
        ctx.setLineWidth(4.5)
        ctx.setLineJoin(.round)
        ctx.addPath(dome.cgPath)
        ctx.strokePath()

        // Tufts
        let th  = w * FaceGeo.tuftHFrac
        let thw = w * FaceGeo.tuftHWFrac
        let baseY = cy - hr
        let tufts: [(x: CGFloat, h: CGFloat, lean: CGFloat)] = [
            (-0.18, 0.85, -0.16), (-0.06, 1.0, -0.04),
            (0.06, 0.90, 0.04), (0.18, 0.75, 0.16),
        ]
        for t in tufts {
            let bx = cx + hr * t.x
            let tipX = bx + thw * t.lean * 2
            let tipY = baseY - th * 3 * t.h
            let p = UIBezierPath()
            p.move(to: CGPoint(x: bx - thw * 0.5, y: baseY + th * 0.15))
            p.addLine(to: CGPoint(x: tipX, y: tipY))
            p.addLine(to: CGPoint(x: bx + thw * 0.5, y: baseY + th * 0.15))
            p.close()
            ctx.setFillColor(FaceColors.hair.cgColor)
            ctx.addPath(p.cgPath)
            ctx.fillPath()
            ctx.setStrokeColor(FaceColors.outline.cgColor)
            ctx.setLineWidth(3.5)
            ctx.setLineJoin(.round)
            ctx.addPath(p.cgPath)
            ctx.strokePath()
        }
    }

    // MARK: - Eye

    private static func drawEye(ctx: CGContext, cx: CGFloat, cy: CGFloat,
                                 r: CGFloat, hlR: CGFloat,
                                 hlOx: CGFloat, hlOy: CGFloat,
                                 blink: CGFloat, emo: Emotion) {
        let scale: CGFloat = {
            switch emo {
            case .surprised: return 1.30
            case .sleepy:    return 0.50
            case .happy:     return 0.82
            default:         return 1.0
            }
        }()
        let rr = r * scale
        let vs = max(0, 1 - blink)
        if vs < 0.02 { return }

        if emo == .sleepy && blink < 0.3 {
            // Flat oval
            let sw = rr * 1.6
            let sh = rr * 0.28
            ctx.setFillColor(FaceColors.eye.cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - sw, y: cy - sh, width: sw * 2, height: sh * 2))
        } else {
            let eh = rr * 2 * vs
            ctx.setFillColor(FaceColors.eye.cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - rr, y: cy - eh / 2, width: rr * 2, height: eh))
            // Highlight
            if vs > 0.45 {
                ctx.setFillColor(FaceColors.eyeLight.cgColor)
                ctx.fillEllipse(in: CGRect(x: cx + hlOx - hlR, y: cy - hlOy - hlR,
                                           width: hlR * 2, height: hlR * 2))
            }
        }
    }

    // MARK: - Eyebrow

    private static func drawBrow(ctx: CGContext, cx: CGFloat, top: CGFloat,
                                  half: CGFloat, emo: Emotion, left: Bool) {
        ctx.setStrokeColor(FaceColors.brow.withAlphaComponent(0.88).cgColor)
        ctx.setLineWidth(FaceGeo.browThick)
        ctx.setLineCap(.round)

        let x0 = cx - half, x1 = cx + half, mid = cx
        let arch = half * 0.35
        let p = UIBezierPath()
        p.lineWidth = FaceGeo.browThick
        p.lineCapStyle = .round

        switch emo {
        case .happy:
            p.move(to: CGPoint(x: x0, y: top))
            p.addQuadCurve(to: CGPoint(x: x1, y: top), controlPoint: CGPoint(x: mid, y: top - arch * 1.2))
        case .sad:
            let inner = left ? x1 : x0; let outer = left ? x0 : x1
            p.move(to: CGPoint(x: outer, y: top + half * 0.22))
            p.addQuadCurve(to: CGPoint(x: inner, y: top - half * 0.08), controlPoint: CGPoint(x: mid, y: top + half * 0.03))
        case .surprised:
            let ha = arch * 1.5
            p.move(to: CGPoint(x: x0, y: top - ha * 0.5))
            p.addQuadCurve(to: CGPoint(x: x1, y: top - ha * 0.5), controlPoint: CGPoint(x: mid, y: top - ha * 1.2))
        case .curious:
            let raise: CGFloat = left ? arch * 0.9 : -arch * 0.1
            p.move(to: CGPoint(x: x0, y: top - raise * 0.5))
            p.addQuadCurve(to: CGPoint(x: x1, y: top - raise * 0.05), controlPoint: CGPoint(x: mid, y: top - raise - arch * 0.4))
        case .sleepy:
            p.move(to: CGPoint(x: x0, y: top - arch * 0.1))
            p.addQuadCurve(to: CGPoint(x: x1, y: top + half * 0.1), controlPoint: CGPoint(x: mid, y: top + arch * 0.06))
        case .shy:
            p.move(to: CGPoint(x: x0, y: top - arch * 0.1))
            p.addQuadCurve(to: CGPoint(x: x1, y: top - arch * 0.1), controlPoint: CGPoint(x: mid, y: top - arch * 0.75))
        default:
            p.move(to: CGPoint(x: x0, y: top))
            p.addQuadCurve(to: CGPoint(x: x1, y: top), controlPoint: CGPoint(x: mid, y: top - arch * 0.55))
        }
        ctx.addPath(p.cgPath)
        ctx.strokePath()
    }

    // MARK: - Nose

    private static func drawNose(ctx: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat) {
        ctx.setFillColor(FaceColors.nose.cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r * 0.6, width: r * 2, height: r * 1.2))
    }

    // MARK: - Blush

    private static func drawBlush(ctx: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat) {
        ctx.setFillColor(FaceColors.blush.cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r * 0.65, width: r * 2, height: r * 1.3))
    }

    // MARK: - Mouth

    private static func drawMouth(ctx: CGContext, cx: CGFloat, cy: CGFloat,
                                   hw: CGFloat, emo: Emotion,
                                   speaking: Bool, t: CGFloat) {
        if emo == .surprised {
            let rr = hw * (speaking ? max(0.28, t) * 0.5 : 0.18)
            ctx.setFillColor(FaceColors.mouthDark.cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - rr, y: cy - rr * 0.4, width: rr * 2, height: rr * 1.2))
            return
        }

        let open = speaking && t > 0.08
        if open {
            let ow = hw * (0.30 + t * 0.42)
            let oh = max(hw * t * 0.55, ow * 0.28)
            let cr = ow * 0.40
            let mr = CGRect(x: cx - ow, y: cy - oh * 0.32, width: ow * 2, height: oh)
            let path = UIBezierPath(roundedRect: mr, cornerRadius: cr)
            ctx.setFillColor(FaceColors.mouthDark.cgColor)
            ctx.addPath(path.cgPath)
            ctx.fillPath()
            ctx.setStrokeColor(FaceColors.mouth.cgColor)
            ctx.setLineWidth(1.8)
            ctx.addPath(path.cgPath)
            ctx.strokePath()
        } else {
            let bw: CGFloat = { switch emo { case .happy: return 0.95; case .sad: return 0.48; default: return 0.60 } }()
            let ww = hw * bw
            let arch: CGFloat = { switch emo { case .happy: return hw * 0.45; case .sad: return -hw * 0.22; default: return hw * 0.10 } }()
            let thick = hw * 0.15
            let smile = UIBezierPath()
            smile.lineWidth = thick
            smile.lineCapStyle = .round
            smile.move(to: CGPoint(x: cx - ww, y: cy))
            smile.addQuadCurve(to: CGPoint(x: cx + ww, y: cy), controlPoint: CGPoint(x: cx, y: cy + arch))
            ctx.setStrokeColor(FaceColors.mouth.cgColor)
            ctx.setLineWidth(thick)
            ctx.setLineCap(.round)
            ctx.addPath(smile.cgPath)
            ctx.strokePath()
        }
    }

    // MARK: - Indicators

    private static func drawListen(ctx: CGContext, cx: CGFloat, y: CGFloat) {
        let rr: [CGFloat] = [5, 9, 5]
        let oo: [CGFloat] = [-18, 0, 18]
        ctx.setFillColor(FaceColors.mouth.withAlphaComponent(0.65).cgColor)
        for i in 0..<3 {
            ctx.fillEllipse(in: CGRect(x: cx + oo[i] - rr[i], y: y - rr[i],
                                        width: rr[i] * 2, height: rr[i] * 2))
        }
    }

    private static func drawThink(ctx: CGContext, cx: CGFloat, y: CGFloat) {
        let r: CGFloat = 4.5
        let s: CGFloat = 13
        ctx.setFillColor(FaceColors.mouth.withAlphaComponent(0.55).cgColor)
        for i in -1...1 {
            ctx.fillEllipse(in: CGRect(x: cx + CGFloat(i) * s - r, y: y - r,
                                        width: r * 2, height: r * 2))
        }
    }
}
