//
//  RobotFaceView.swift
//  Avatar
//
//  UIViewRepresentable wrapping a UIKit UIView that draws the stick figure.
//  Uses CADisplayLink for animation (blink, speak, idle wander, antics).
//  Frame rate capped at 20 fps to reduce CPU/thermal load.
//  iOS 14 compatible (SwiftUI Canvas requires iOS 15).
//

import SwiftUI
import UIKit

// MARK: - UIKit Face View

final class FaceDisplayView: UIView {

    /// Target display refresh rate. 20 fps is smooth enough for the stick figure
    /// while dramatically reducing CPU vs. the default 60 fps.
    private static let targetFPS: Int = 20

    var robotState: RobotState = RobotState() {
        didSet { setNeedsDisplay() }
    }

    // Animation parameters
    var blinkProgress: CGFloat = 0
    var speakAmount: CGFloat = 0
    var thinkPhase: CGFloat = 0
    var idleWander: CGFloat = 0
    var listenPulse: CGFloat = 0
    var breatheScale: CGFloat = 1.0
    var anticPhase: CGFloat = 0       // goofy antic animation 0→1
    var jumpPhase: CGFloat = 0        // jump animation 0→1
    var walkPhase: CGFloat = 0        // walk progress 0→1
    var walkType: WalkType = .none    // current walk direction
    var stageWalkPhase: CGFloat = 0   // stage walk during speaking
    var gesturePhase: CGFloat = 0     // arm gesture variety during speaking
    var emphasisArm: Int = -1         // -1=none, 0=left, 1=right
    var emphasisPhase: CGFloat = 0    // 0→1 raise progress

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
    private var listenTimer: Timer?
    private var breatheTimer: Timer?
    private var anticTimer: Timer?
    private var jumpTimer: Timer?
    private var walkTimer: Timer?
    private var isStageWalkActive = false
    private var stageWalkStartTime: CFTimeInterval = 0
    private var emphasisTimer: Timer?
    private var emphasisAnimTimer: Timer?

    // Track previous state for trigger detection
    private var lastAnticTrigger: Int = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = StickColors.bg
        setupAnimation()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = StickColors.bg
        setupAnimation()
    }

    private func setupAnimation() {
        displayLink = CADisplayLink(target: self, selector: #selector(animateStep))
        displayLink?.preferredFramesPerSecond = Self.targetFPS
        displayLink?.add(to: .main, forMode: .common)
        wanderStartTime = CACurrentMediaTime()
    }

    @objc private func animateStep() {
        let now = CACurrentMediaTime()

        // Idle wander
        let elapsed = now - wanderStartTime
        if elapsed >= wanderPeriod {
            wanderStartTime = now
            wanderTargetStart = wanderTargetEnd
            wanderTargetEnd = CGFloat.random(in: -1...1)
            wanderPeriod = CFTimeInterval.random(in: 2...3.5)
        }
        let t = CGFloat(elapsed / wanderPeriod)
        idleWander = wanderTargetStart + (wanderTargetEnd - wanderTargetStart) * t

        // Stage walk: continuous pacing cycle (~5s per full left-right-left)
        if isStageWalkActive {
            let stageElapsed = now - stageWalkStartTime
            let cycleDuration: CFTimeInterval = 5.0   // human speaker pacing speed
            stageWalkPhase = CGFloat(stageElapsed.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration)
            // Gesture variety: independent slower cycle for arm pattern changes
            let gestureCycle: CFTimeInterval = 3.2
            gesturePhase = CGFloat(stageElapsed.truncatingRemainder(dividingBy: gestureCycle) / gestureCycle)
        }

        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        StickFigureDrawer.drawStickFigure(
            in: rect,
            mode: robotState.mode,
            emotion: robotState.emotion,
            speakAmount: speakAmount,
            thinkPhase: thinkPhase,
            listenPulse: listenPulse,
            breatheAmount: breatheScale,
            idleWander: idleWander,
            blinkProgress: blinkProgress,
            anticTrigger: robotState.anticTrigger,
            jumpPhase: jumpPhase,
            isSpeaking: robotState.isSpeaking,
            enginesReady: robotState.enginesReady,
            walkType: walkType,
            walkPhase: walkPhase,
            stageWalkPhase: stageWalkPhase,
            gesturePhase: gesturePhase,
            emphasisArm: emphasisArm,
            emphasisPhase: emphasisPhase
        )
    }

    // MARK: - Blink

    func triggerBlink() {
        guard !isBlinking else { return }
        isBlinking = true
        blinkTimer?.invalidate()

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
        speakTimer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] _ in
            isOpen.toggle()
            self?.speakAmount = isOpen ? 1.0 : 0.15
        }
        // Stage walk: driven by CADisplayLink animateStep() for vsync-smooth pacing
        isStageWalkActive = true
        stageWalkStartTime = CACurrentMediaTime()
        stageWalkPhase = 0
        // Emphasis gestures: random arm raises during speech
        emphasisArm = -1
        emphasisPhase = 0
        scheduleNextEmphasis()
    }

    func stopSpeakingAnimation() {
        speakTimer?.invalidate()
        speakTimer = nil
        speakAmount = 0
        isStageWalkActive = false
        stageWalkPhase = 0
        gesturePhase = 0
        emphasisTimer?.invalidate()
        emphasisTimer = nil
        emphasisAnimTimer?.invalidate()
        emphasisAnimTimer = nil
        emphasisArm = -1
        emphasisPhase = 0
    }

    // MARK: - Emphasis Gestures

    private func scheduleNextEmphasis() {
        emphasisTimer?.invalidate()
        let delay = TimeInterval.random(in: 3...8)  // random interval between raises
        emphasisTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.triggerEmphasis()
        }
    }

    private func triggerEmphasis() {
        guard isStageWalkActive else { return }
        // Pick a random arm
        emphasisArm = Int.random(in: 0...1)  // 0=left, 1=right
        emphasisPhase = 0
        // Animate: raise 0→1 over 0.4s, hold 0.3s, lower 1→0 over 0.4s
        let raiseDuration: TimeInterval = 0.4
        let holdDuration: TimeInterval = 0.3
        let lowerDuration: TimeInterval = 0.4
        let totalDuration = raiseDuration + holdDuration + lowerDuration
        let startTime = CACurrentMediaTime()

        emphasisAnimTimer?.invalidate()
        emphasisAnimTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / Double(Self.targetFPS), repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - startTime
            if elapsed < raiseDuration {
                self.emphasisPhase = CGFloat(elapsed / raiseDuration)       // 0→1
            } else if elapsed < raiseDuration + holdDuration {
                self.emphasisPhase = 1.0                                     // hold
            } else if elapsed < totalDuration {
                let lowerElapsed = elapsed - raiseDuration - holdDuration
                self.emphasisPhase = CGFloat(1.0 - lowerElapsed / lowerDuration)  // 1→0
            } else {
                self.emphasisPhase = 0
                self.emphasisArm = -1
                timer.invalidate()
            }
        }
        // Schedule next emphasis after this one completes
        emphasisTimer?.invalidate()
        emphasisTimer = Timer.scheduledTimer(withTimeInterval: totalDuration + TimeInterval.random(in: 2...6), repeats: false) { [weak self] _ in
            self?.triggerEmphasis()
        }
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

    // MARK: - Listen Pulse

    func startListeningAnimation() {
        listenTimer?.invalidate()
        listenTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            UIView.animate(withDuration: 0.5, delay: 0, options: [.curveEaseInOut]) {
                self?.listenPulse = self?.listenPulse == 1.0 ? 0.3 : 1.0
            }
        }
    }

    func stopListeningAnimation() {
        listenTimer?.invalidate()
        listenTimer = nil
        listenPulse = 0
    }

    // MARK: - Breathe (idle)

    func startBreathingAnimation() {
        breatheTimer?.invalidate()
        breatheTimer = Timer.scheduledTimer(withTimeInterval: 3.6, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            UIView.animate(withDuration: 1.8, delay: 0, options: [.curveEaseInOut]) {
                self.breatheScale = self.breatheScale > 1.0 ? 0.97 : 1.03
            }
        }
        // Fire immediately
        if breatheScale == 1.0 {
            breatheTimer?.fire()
        }
    }

    func stopBreathingAnimation() {
        breatheTimer?.invalidate()
        breatheTimer = nil
        breatheScale = 1.0
    }

    // MARK: - Antic (goofy random action)

    func triggerAntic() {
        // Run antic animation: 0 → 1 over 400ms, hold 800ms, 0 over 600ms
        anticTimer?.invalidate()
        anticPhase = 0
        let tickInterval = 1.0 / Double(Self.targetFPS)

        // Phase 1: in
        animateAntic(to: 1.0, duration: 0.8, tick: tickInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                // Phase 2: out
                self?.animateAntic(to: 0.0, duration: 1.2, tick: tickInterval, completion: {})
            }
        }
    }

    private func animateAntic(to target: CGFloat, duration: TimeInterval, tick: TimeInterval, completion: @escaping () -> Void) {
        let start = anticPhase
        let steps = max(1, Int(duration / tick))
        var i = 0
        anticTimer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] timer in
            i += 1
            let progress = CGFloat(i) / CGFloat(steps)
            self?.anticPhase = start + (target - start) * min(progress, 1.0)
            if progress >= 1.0 {
                timer.invalidate()
                completion()
            }
        }
    }

    // MARK: - Jump

    func triggerJump() {
        jumpTimer?.invalidate()
        jumpPhase = 0
        let tick = 1.0 / Double(Self.targetFPS)

        // Phase 1: crouch (0 → 0.25)
        animateJump(to: 0.25, duration: 0.4, tick: tick) {
            // Phase 2: launch up (0.25 → 0.6)
            self.animateJump(to: 0.6, duration: 0.5, tick: tick) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    // Phase 3: fall + land (0.6 → 1.0)
                    self?.animateJump(to: 1.0, duration: 0.6, tick: tick) {
                        self?.jumpPhase = 0
                    }
                }
            }
        }
    }

    private func animateJump(to target: CGFloat, duration: TimeInterval, tick: TimeInterval, completion: @escaping () -> Void) {
        let start = jumpPhase
        let steps = max(1, Int(duration / tick))
        var i = 0
        jumpTimer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] timer in
            i += 1
            let progress = CGFloat(i) / CGFloat(steps)
            self?.jumpPhase = start + (target - start) * min(progress, 1.0)
            if progress >= 1.0 {
                timer.invalidate()
                completion()
            }
        }
    }

    // MARK: - Walk

    func triggerWalk(_ type: WalkType) {
        walkTimer?.invalidate()
        walkType = type
        walkPhase = 0
        let tick = 1.0 / Double(Self.targetFPS)
        let duration: TimeInterval = (type == .left || type == .right) ? 4.0 : 5.0
        let steps = max(1, Int(duration / tick))
        var i = 0
        walkTimer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] timer in
            i += 1
            let progress = CGFloat(i) / CGFloat(steps)
            self?.walkPhase = min(progress, 1.0)
            if progress >= 1.0 {
                timer.invalidate()
                if type == .away {
                    // Pause briefly at far distance, then walk back toward camera
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self?.triggerWalk(.toward)
                    }
                } else {
                    self?.walkType = .none
                    self?.walkPhase = 0
                }
            }
        }
    }

    // MARK: - Pause / Resume

    func setPaused(_ paused: Bool) {
        displayLink?.isPaused = paused
    }

    // MARK: - Adaptive Frame Rate

    func updateFrameRate(for mode: RobotMode) {
        let needsFullRate: Bool = {
            switch mode {
            case .listening, .speaking, .thinking:
                return true
            case .idle, .looking:
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
        listenTimer?.invalidate()
        breatheTimer?.invalidate()
        anticTimer?.invalidate()
        jumpTimer?.invalidate()
        walkTimer?.invalidate()
        emphasisTimer?.invalidate()
        emphasisAnimTimer?.invalidate()
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

        // Adaptive frame rate
        if context.coordinator.lastMode != robotState.mode {
            context.coordinator.lastMode = robotState.mode
            uiView.updateFrameRate(for: robotState.mode)
        }

        // Handle blink trigger
        if context.coordinator.lastBlinkTrigger != blinkTrigger {
            context.coordinator.lastBlinkTrigger = blinkTrigger
            uiView.triggerBlink()
        }

        // Handle antic trigger
        if context.coordinator.lastAnticTrigger != robotState.anticTrigger {
            context.coordinator.lastAnticTrigger = robotState.anticTrigger
            if robotState.anticTrigger > 0 {
                uiView.triggerAntic()
                // ~20% of antics trigger a jump
                if robotState.anticTrigger % 5 == 4 {
                    uiView.triggerJump()
                }
                // Walk antics (only when no jump/squat/lie)
                let isJump  = robotState.anticTrigger % 5 == 4
                let isSquat = robotState.anticTrigger % 7 == 3
                let isLie   = robotState.anticTrigger > 3 && robotState.anticTrigger % 13 == 7
                if !isJump && !isSquat && !isLie {
                    if robotState.anticTrigger % 9 == 2 {
                        uiView.triggerWalk(.left)
                    } else if robotState.anticTrigger % 9 == 5 {
                        uiView.triggerWalk(.right)
                    } else if robotState.anticTrigger % 11 == 3 {
                        uiView.triggerWalk(.away)
                    } else if robotState.anticTrigger % 11 == 8 {
                        uiView.triggerWalk(.toward)
                    }
                }
            }
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

        // Handle listening
        if robotState.mode == .listening && !context.coordinator.wasListening {
            uiView.startListeningAnimation()
        } else if robotState.mode != .listening && context.coordinator.wasListening {
            uiView.stopListeningAnimation()
        }
        context.coordinator.wasListening = (robotState.mode == .listening)

        // Handle breathing (idle only)
        if robotState.mode == .idle && !context.coordinator.wasIdle {
            uiView.startBreathingAnimation()
        } else if robotState.mode != .idle && context.coordinator.wasIdle {
            uiView.stopBreathingAnimation()
        }
        context.coordinator.wasIdle = (robotState.mode == .idle)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var lastBlinkTrigger: Int = -1
        var lastAnticTrigger: Int = 0
        var wasSpeaking: Bool = false
        var wasThinking: Bool = false
        var wasListening: Bool = false
        var wasIdle: Bool = true
        var lastMode: RobotMode?
    }
}
