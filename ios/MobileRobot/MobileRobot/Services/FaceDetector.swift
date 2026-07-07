//
//  FaceDetector.swift
//  MobileRobot
//
//  Wraps AVFoundation + Vision for face detection.
//  Ported from Android: FaceDetector.kt (CameraX + ML Kit)
//
//  Uses front camera + VNDetectFaceRectanglesRequest.
//  Emits normalized face coordinates via Combine publisher.
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
    private let sessionQueue = DispatchQueue(label: "dev.mobilerobot.face.session")
    private let analysisQueue = DispatchQueue(label: "dev.mobilerobot.face.analysis", qos: .userInitiated)

    private var isRunning = false

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
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension FaceDetector: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectFaceRectanglesRequest { [weak self] request, error in
            guard let self = self else { return }

            if let error = error {
                os_log(.error, "FaceDetector: Vision error: %{public}@", error.localizedDescription)
                self._faces.send(nil)
                return
            }

            guard let results = request.results as? [VNFaceObservation], !results.isEmpty else {
                self._faces.send(nil)
                return
            }

            // Take the most prominent face (first result)
            let face = results[0]
            let box = face.boundingBox

            // Vision coord system: origin bottom-left, 0..1
            // Convert: flip Y for screen coords (origin top-left)
            // For front camera with mirroring, flip X as well
            let cx = Float(1.0 - box.midX)         // mirror X for front camera
            let cy = Float(1.0 - box.midY)          // flip Y to top-left origin
            let faceWidth = Float(box.width)

            // Note: VNDetectFaceRectanglesRequest does not provide smile or
            // eye-open probabilities. Use VNDetectFaceLandmarksRequest +
            // additional processing if these are needed in the future.
            let result = FaceDetectionResult(
                cx: cx,
                cy: cy,
                faceWidth: faceWidth,
                smileProbability: nil,
                leftEyeOpenProbability: nil
            )

            self._faces.send(result)
        }

        request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .leftMirrored,  // front camera mirrored
            options: [:]
        )

        try? handler.perform([request])
    }
}
