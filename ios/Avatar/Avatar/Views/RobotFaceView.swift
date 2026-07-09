//
//  RobotFaceView.swift
//  Avatar
//
//  UIViewRepresentable wrapping a UIKit UIView that draws the cartoon boy face.
//  Uses CADisplayLink for animation (blink, speak, idle wander).
//  Frame rate capped at 20 fps to reduce CPU/thermal load.
//  iOS 14 compatible (SwiftUI Canvas requires iOS 15).
//

import SwiftUI
import UIKit

// MARK: - UIKit Face View

final class FaceDisplayView: UIView {

    /// Target display refresh rate. 20 fps is smooth enough for the cartoon face
    /// while dramatically reducing CPU vs. the default 60 fps.
    private static let targetFPS: Int = 20

    var robotState: RobotState = RobotState() {
        didSet { setNeedsDisplay() }
    }

    // Smoothly interpolated face target (for eye tracking)
    var targetX: CGFloat = 0.5
    var targetY: CGFloat = 0.5

    // Animation parameters
    var blinkProgress: CGFloat = 0
    var speakAmount: CGFloat = 0
    var thinkPhase: CGFloat = 0
    var idleWander: CGFloat = 0

    // Timers
    private var displayLink: CADisplayLink?
    private var wanderStartTime: CFTimeInterval = 0
    private var wanderPeriod: CFTimeInterval = 3.0
    private var wanderTargetStart: CGFloat = 0
    private var wanderTargetEnd: CGFloat = 1
    private var blinkTimer: Timer?
    private var isBlinking = false
    private var speakTimer: Timer?
    private var thinkTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = FaceColors.bg
        setupAnimation()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = FaceColors.bg
        setupAnimation()
    }

    private func setupAnimation() {
        displayLink = CADisplayLink(target: self, selector: #selector(animateStep))
        // preferredFramesPerSecond available iOS 10+
        displayLink?.preferredFramesPerSecond = Self.targetFPS
        displayLink?.add(to: .main, forMode: .common)
        wanderStartTime = CACurrentMediaTime()
    }

    @objc private func animateStep() {
        let now = CACurrentMediaTime()

        // Idle wander — advance by the expected frame delta since we're at
        // reduced frame rate (targetFPS), not screen refresh rate.
        let elapsed = now - wanderStartTime
        if elapsed >= wanderPeriod {
            wanderStartTime = now
            wanderTargetStart = wanderTargetEnd
            wanderTargetEnd = CGFloat.random(in: -1...1)
            wanderPeriod = CFTimeInterval.random(in: 2...3.5)
        }
        let t = CGFloat((elapsed / wanderPeriod))
        idleWander = wanderTargetStart + (wanderTargetEnd - wanderTargetStart) * t

        // Smooth target interpolation for eye tracking — scale lerp factor
        // for reduced frame rate so tracking still feels responsive.
        let lerpFactor: CGFloat = 0.45  // ~3× normal to compensate for 1/3 frame rate
        if robotState.faceTargetX != nil {
            let target = CGFloat(robotState.faceTargetX ?? 0.5)
            targetX += (target - targetX) * lerpFactor
            targetY += (CGFloat(robotState.faceTargetY ?? 0.5) - targetY) * lerpFactor
        } else {
            targetX += (0.5 - targetX) * 0.12
            targetY += (0.5 - targetY) * 0.12
        }

        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        FaceDrawer.drawFace(
            in: rect,
            state: robotState,
            targetX: targetX,
            targetY: targetY,
            idleWander: idleWander,
            blinkProgress: blinkProgress,
            speakAmount: speakAmount,
            thinkPhase: thinkPhase
        )
    }

    // MARK: - Blink

    func triggerBlink() {
        guard !isBlinking else { return }
        isBlinking = true
        blinkTimer?.invalidate()

        // Blink: close → hold → open
        animateBlinkPhase(to: 1.0, duration: 0.08) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.animateBlinkPhase(to: 0.0, duration: 0.08) {
                    self?.isBlinking = false
                }
            }
        }
    }

    private func animateBlinkPhase(to target: CGFloat, duration: TimeInterval, completion: @escaping () -> Void) {
        let start = blinkProgress
        let tickInterval = 1.0 / Double(Self.targetFPS)
        let steps = max(1, Int(duration / tickInterval))
        var i = 0
        blinkTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] timer in
            i += 1
            let progress = CGFloat(i) / CGFloat(steps)
            self?.blinkProgress = start + (target - start) * min(progress, 1.0)
            if progress >= 1.0 {
                timer.invalidate()
                completion()
            }
        }
    }

    // MARK: - Speak

    func startSpeakingAnimation() {
        speakTimer?.invalidate()
        var isOpen = false
        speakTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            isOpen.toggle()
            self?.speakAmount = isOpen ? 1.0 : 0.2
        }
    }

    func stopSpeakingAnimation() {
        speakTimer?.invalidate()
        speakTimer = nil
        speakAmount = 0
    }

    // MARK: - Think

    func startThinkingAnimation() {
        thinkTimer?.invalidate()
        thinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            UIView.animate(withDuration: 0.8, delay: 0, options: [.curveEaseInOut]) {
                self?.thinkPhase = self?.thinkPhase == 1.0 ? -1.0 : 1.0
            }
        }
    }

    func stopThinkingAnimation() {
        thinkTimer?.invalidate()
        thinkTimer = nil
        thinkPhase = 0
    }

    // MARK: - Pause / Resume

    func setPaused(_ paused: Bool) {
        displayLink?.isPaused = paused
    }

    // MARK: - Adaptive Frame Rate

    /// Drop to a lower frame rate when the robot is idle (no face, not
    /// speaking/thinking) to save even more CPU.
    func updateFrameRate(for mode: RobotMode) {
        let needsFullRate: Bool = {
            switch mode {
            case .listening, .speaking, .thinking:
                return true
            case .idle, .watching:
                return false
            }
        }()
        let fps = needsFullRate ? Self.targetFPS : 10
        displayLink?.preferredFramesPerSecond = fps
    }

    deinit {
        displayLink?.invalidate()
        blinkTimer?.invalidate()
        speakTimer?.invalidate()
        thinkTimer?.invalidate()
    }
}

// MARK: - SwiftUI Representable (iOS 14 compatible)

struct RobotFaceView: UIViewRepresentable {
    @Binding var robotState: RobotState
    @Binding var blinkTrigger: Int
    var isPaused: Bool = false

    func makeUIView(context: Context) -> FaceDisplayView {
        FaceDisplayView()
    }

    func updateUIView(_ uiView: FaceDisplayView, context: Context) {
        uiView.robotState = robotState

        // Pause display link when settings is shown
        uiView.setPaused(isPaused)

        // Adaptive frame rate: lower when idle/watching
        if context.coordinator.lastMode != robotState.mode {
            context.coordinator.lastMode = robotState.mode
            uiView.updateFrameRate(for: robotState.mode)
        }

        // Handle blink trigger
        if context.coordinator.lastBlinkTrigger != blinkTrigger {
            context.coordinator.lastBlinkTrigger = blinkTrigger
            uiView.triggerBlink()
        }

        // Handle speaking
        if robotState.isSpeaking && !context.coordinator.wasSpeaking {
            uiView.startSpeakingAnimation()
        } else if !robotState.isSpeaking && context.coordinator.wasSpeaking {
            uiView.stopSpeakingAnimation()
        }
        context.coordinator.wasSpeaking = robotState.isSpeaking

        // Handle thinking
        if robotState.mode == .thinking && !context.coordinator.wasThinking {
            uiView.startThinkingAnimation()
        } else if robotState.mode != .thinking && context.coordinator.wasThinking {
            uiView.stopThinkingAnimation()
        }
        context.coordinator.wasThinking = (robotState.mode == .thinking)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var lastBlinkTrigger: Int = -1
        var wasSpeaking: Bool = false
        var wasThinking: Bool = false
        var lastMode: RobotMode?
    }
}
