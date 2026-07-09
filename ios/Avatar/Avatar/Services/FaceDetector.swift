//
//  FaceDetector.swift
//  Avatar
//
//  Wraps AVFoundation + Vision for face detection and expression analysis.
//  Ported from Android: FaceDetector.kt (CameraX + ML Kit)
//
//  Uses front camera + VNDetectFaceLandmarksRequest to get:
//    - Face bounding box (position tracking)
//    - Facial landmarks → expression metrics (smile, eyebrows, eyes, mouth)
//  Emits normalized results via Combine publisher.
//

import Foundation
import AVFoundation
import Vision
import Combine
import os.log

class FaceDetector: NSObject, ObservableObject {

    /// Emits the most recent detection result, or nil when no face is visible.
    private let _faces = PassthroughSubject<FaceDetectionResult?, Never>()
    var faces: AnyPublisher<FaceDetectionResult?, Never> {
        _faces.eraseToAnyPublisher()
    }

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "dev.avatar.face.session")
    private let analysisQueue = DispatchQueue(label: "dev.avatar.face.analysis", qos: .utility)

    private var isRunning = false

    /// Frame skip counter: only run Vision every N camera frames to reduce
    /// CPU/Neural Engine load. At ~30 fps camera, every 4th frame ≈ 7.5 Hz,
    /// which is plenty for smooth face tracking.
    private let visionFrameInterval = 4
    private var frameCounter = 0

    /// Adaptive frame rate: when no face is detected for this many seconds,
    /// drop the camera to 5 fps to save power. Restore to 30 fps as soon as
    /// a face reappears.
    private let lowFpsThreshold: CFTimeInterval = 5.0
    private var lastFaceTime: CFTimeInterval = 0
    private var lowFpsMode = false

    /// Smoothing: keep a rolling window of recent emotions to avoid jitter.
    private let emotionWindowSize = 5
    private var emotionWindow: [Emotion?] = []

    // MARK: - Permission

    static var cameraPermissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    static func requestPermission(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
    }

    // MARK: - Start / Stop

    func start() {
        guard !isRunning else { return }
        isRunning = true

        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .medium

            // Front camera
            guard let camera = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .front
            ) else {
                os_log(.error, "FaceDetector: no front camera available")
                self.session.commitConfiguration()
                return
            }

            guard let input = try? AVCaptureDeviceInput(device: camera) else {
                os_log(.error, "FaceDetector: failed to create camera input")
                self.session.commitConfiguration()
                return
            }

            if self.session.canAddInput(input) {
                self.session.addInput(input)
            }

            // Video output
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.analysisQueue)

            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }

            // Mirror front camera video output
            if let connection = self.videoOutput.connection(with: .video) {
                connection.isVideoMirrored = true
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
            }

            self.session.commitConfiguration()
            self.session.startRunning()
            os_log(.info, "FaceDetector: started")
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            os_log(.info, "FaceDetector: stopped")
        }
    }

    // MARK: - Adaptive Frame Rate

    /// Drop the camera to 5 fps when no face has been detected for a while.
    /// Camera sensor + ISP are the #1 power consumer; 5 fps is plenty for
    /// "is someone there?" detection while dramatically reducing energy use.
    private func switchToLowFps() {
        guard !lowFpsMode else { return }
        lowFpsMode = true

        sessionQueue.async { [weak self] in
            guard let self = self,
                  let device = self.session.inputs
                    .compactMap({ ($0 as? AVCaptureDeviceInput)?.device }).first else { return }

            do {
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 5)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 5)
                device.unlockForConfiguration()
                os_log(.info, "FaceDetector: switched to low-power 5 fps")
            } catch {
                os_log(.error, "FaceDetector: failed to set low fps: %{public}@",
                       error.localizedDescription)
                self.lowFpsMode = false
            }
        }
    }

    /// Restore the camera to 30 fps when a face reappears.
    private func switchToNormalFps() {
        guard lowFpsMode else { return }
        lowFpsMode = false

        sessionQueue.async { [weak self] in
            guard let self = self,
                  let device = self.session.inputs
                    .compactMap({ ($0 as? AVCaptureDeviceInput)?.device }).first else { return }

            do {
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                device.unlockForConfiguration()
                os_log(.info, "FaceDetector: restored to 30 fps")
            } catch {
                os_log(.error, "FaceDetector: failed to set normal fps: %{public}@",
                       error.localizedDescription)
                self.lowFpsMode = true
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension FaceDetector: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Throttle: only run Vision detection every N frames.
        // In low-power mode (5 fps camera), run on every frame.
        frameCounter += 1
        let interval = lowFpsMode ? 1 : visionFrameInterval
        if frameCounter % interval != 0 { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Use landmarks request — it also provides the bounding box.
        let request = VNDetectFaceLandmarksRequest { [weak self] request, error in
            guard let self = self else { return }

            if let error = error {
                os_log(.error, "FaceDetector: Vision error: %{public}@", error.localizedDescription)
                self._faces.send(nil)
                return
            }

            guard let results = request.results as? [VNFaceObservation], !results.isEmpty else {
                self._faces.send(nil)
                // Adaptive frame rate: if no face for too long, drop camera to 5 fps.
                let now = CACurrentMediaTime()
                if !self.lowFpsMode && now - self.lastFaceTime > self.lowFpsThreshold {
                    self.switchToLowFps()
                }
                return
            }

            // Face detected — reset the idle timer and restore full frame rate.
            self.lastFaceTime = CACurrentMediaTime()
            if self.lowFpsMode {
                self.switchToNormalFps()
            }

            // Take the most prominent face
            let face = results[0]
            let box = face.boundingBox

            // Vision coord system: origin bottom-left, 0..1
            // Convert: flip Y for screen coords (origin top-left)
            // For front camera with mirroring, flip X as well
            let cx = Float(1.0 - box.midX)
            let cy = Float(1.0 - box.midY)
            let faceWidth = Float(box.width)

            // Compute expression metrics from landmarks
            let smile = face.landmarks.flatMap { Self.computeSmile(from: $0) } ?? 0
            let browRaise = face.landmarks.flatMap { Self.computeEyebrowRaise(from: $0) } ?? 0
            let mouthO = face.landmarks.flatMap { Self.computeMouthOpen(from: $0) } ?? 0
            let leftEye = face.landmarks.flatMap { Self.computeEyeOpen($0.leftEye) } ?? 1.0
            let rightEye = face.landmarks.flatMap { Self.computeEyeOpen($0.rightEye) } ?? 1.0

            let result = FaceDetectionResult(
                cx: cx,
                cy: cy,
                faceWidth: faceWidth,
                smileAmount: smile,
                eyebrowRaise: browRaise,
                mouthOpen: mouthO,
                leftEyeOpen: leftEye,
                rightEyeOpen: rightEye
            )

            self._faces.send(result)
        }

        request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .leftMirrored,
            options: [:]
        )

        try? handler.perform([request])
    }
}

// MARK: - Expression Computation

private extension FaceDetector {

    /// Smile amount: how much mouth corners are raised above mouth center.
    /// 0 = neutral/frown, 1 = full smile.
    static func computeSmile(from landmarks: VNFaceLandmarks2D) -> Float {
        guard let outerLips = landmarks.outerLips else { return 0 }
        let pts = outerLips.normalizedPoints  // [0..N-1] around outer lip contour

        // In Vision's outerLips: 0=left corner, 6=right corner,
        // 3≈top center (cupid's bow), 9≈bottom center.
        guard pts.count >= 14 else { return 0 }

        let leftCornerY  = Float(pts[0].y)
        let rightCornerY = Float(pts[6].y)
        let topCenterY   = Float(pts[3].y)
        let mouthWidth   = abs(Float(pts[6].x - pts[0].x))

        guard mouthWidth > 0.001 else { return 0 }

        // Average corner elevation relative to top lip center
        let avgCornerY = (leftCornerY + rightCornerY) / 2
        let cornerRise = avgCornerY - topCenterY  // positive = corners above center = smile

        // Normalize by mouth width for scale invariance
        let normalized = cornerRise / mouthWidth
        return max(0, min(1, normalized * 2.5))
    }

    /// Eyebrow raise: how high the eyebrows sit above the eyes.
    /// 0 = resting, 1 = fully raised (surprise).
    static func computeEyebrowRaise(from landmarks: VNFaceLandmarks2D) -> Float {
        guard let leftBrow = landmarks.leftEyebrow,
              let rightBrow = landmarks.rightEyebrow,
              let leftEye = landmarks.leftEye,
              let rightEye = landmarks.rightEye else { return 0 }

        let leftBrowY  = Float(leftBrow.normalizedPoints.map(\.y).min() ?? 0)
        let rightBrowY = Float(rightBrow.normalizedPoints.map(\.y).min() ?? 0)
        let leftEyeY   = Float(leftEye.normalizedPoints.map(\.y).max() ?? 0)
        let rightEyeY  = Float(rightEye.normalizedPoints.map(\.y).max() ?? 0)

        // Distance from top of eye to bottom of eyebrow
        let leftGap  = leftEyeY - leftBrowY
        let rightGap = rightEyeY - rightBrowY

        // Normalize: baseline gap is ~0.05 in Vision coords, surprised ~0.15
        let avgGap = (leftGap + rightGap) / 2
        let normalized = (avgGap - 0.03) / 0.12
        return max(0, min(1, normalized))
    }

    /// Mouth openness: 0 = closed, 1 = wide open.
    static func computeMouthOpen(from landmarks: VNFaceLandmarks2D) -> Float {
        guard let innerLips = landmarks.innerLips else { return 0 }
        let pts = innerLips.normalizedPoints
        guard pts.count >= 6 else { return 0 }

        let topY    = Float(pts.map(\.y).min() ?? 0)
        let bottomY = Float(pts.map(\.y).max() ?? 0)
        let leftX   = Float(pts.map(\.x).min() ?? 0)
        let rightX  = Float(pts.map(\.x).max() ?? 0)

        let mouthHeight = bottomY - topY
        let mouthWidth  = rightX - leftX

        guard mouthWidth > 0.001 else { return 0 }

        let normalized = (mouthHeight / mouthWidth - 0.1) / 0.6
        return max(0, min(1, normalized))
    }

    /// Eye openness: 0 = closed, 1 = wide open.
    static func computeEyeOpen(_ eye: VNFaceLandmarkRegion2D?) -> Float {
        guard let eye = eye else { return 1.0 }
        let pts = eye.normalizedPoints
        guard pts.count >= 6 else { return 1.0 }

        let topY    = Float(pts.map(\.y).min() ?? 0)
        let bottomY = Float(pts.map(\.y).max() ?? 0)
        let leftX   = Float(pts.map(\.x).min() ?? 0)
        let rightX  = Float(pts.map(\.x).max() ?? 0)

        let eyeHeight = bottomY - topY
        let eyeWidth  = rightX - leftX

        guard eyeWidth > 0.001 else { return 1.0 }

        // Typical eye aspect ratio: open ~0.3, closed ~0.05
        let ratio = eyeHeight / eyeWidth
        let normalized = (ratio - 0.03) / 0.25
        return max(0, min(1, normalized))
    }
}
