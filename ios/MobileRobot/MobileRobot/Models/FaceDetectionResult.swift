//
//  FaceDetectionResult.swift
//  MobileRobot
//
//  Result of face detection — normalized to screen-independent coordinates.
//  Ported from Android: FaceDetector.kt (FaceDetectionResult)
//

import Foundation

struct FaceDetectionResult {
    /// Face center X, normalized 0..1 (0=left, 1=right)
    let cx: Float

    /// Face center Y, normalized 0..1 (0=top, 1=bottom)
    let cy: Float

    /// Relative face width (fraction of image width)
    let faceWidth: Float

    /// Smile probability 0..1 if detected, nil otherwise
    let smileProbability: Float?

    /// Left eye open probability 0..1, nil if undetermined
    let leftEyeOpenProbability: Float?
}
