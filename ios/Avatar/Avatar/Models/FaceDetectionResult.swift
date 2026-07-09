//
//  FaceDetectionResult.swift
//  Avatar
//
//  Result of face detection — normalized to screen-independent coordinates.
//  Includes expression metrics derived from Vision face landmarks.
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

    // MARK: - Expression Metrics (0..1 unless noted)

    /// Smile amount: 0 = neutral/frown, 1 = full smile.
    /// Derived from mouth corner elevation vs mouth center.
    let smileAmount: Float

    /// Eyebrow raise: 0 = resting, 1 = fully raised (surprise).
    let eyebrowRaise: Float

    /// Mouth openness: 0 = closed, 1 = wide open.
    let mouthOpen: Float

    /// Left eye openness: 0 = closed, 1 = wide open.
    let leftEyeOpen: Float

    /// Right eye openness: 0 = closed, 1 = wide open.
    let rightEyeOpen: Float

    /// Legacy fields kept for compatibility.
    var smileProbability: Float? { smileAmount }
    var leftEyeOpenProbability: Float? { leftEyeOpen }
}

extension FaceDetectionResult {

    /// The dominant emotion inferred from facial expression.
    /// Returns nil when expression is effectively neutral.
    func inferredEmotion() -> Emotion? {
        // Surprise: eyebrows high AND mouth open
        if eyebrowRaise > 0.55 && mouthOpen > 0.25 {
            return .surprised
        }

        // Happy: clear smile
        if smileAmount > 0.35 {
            return .happy
        }

        // Sad: eyebrows raised (inner) but no smile, mouth closed
        // We approximate with moderate eyebrow + low smile + low mouth open
        if eyebrowRaise > 0.3 && smileAmount < 0.15 && mouthOpen < 0.1 {
            return .sad
        }

        // Sleepy: eyes mostly closed
        let avgEyeOpen = (leftEyeOpen + rightEyeOpen) / 2
        if avgEyeOpen < 0.3 {
            return .sleepy
        }

        // Shy: slight smile + slightly closed eyes
        if smileAmount > 0.15 && avgEyeOpen < 0.55 {
            return .shy
        }

        return nil
    }
}
