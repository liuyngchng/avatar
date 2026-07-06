package com.mobilerobot.app.camera

import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.Executors

/**
 * Result of face detection — normalized to screen-independent coordinates.
 *
 * @param cx face center X, normalized 0..1 (0=left, 1=right)
 * @param cy face center Y, normalized 0..1 (0=top, 1=bottom)
 * @param faceWidth relative face width (fraction of image width)
 * @param smileProbability 0..1 if smile detected, null otherwise
 * @param leftEyeOpenProbability 0..1, null if undetermined
 */
data class FaceDetectionResult(
    val cx: Float,
    val cy: Float,
    val faceWidth: Float,
    val smileProbability: Float? = null,
    val leftEyeOpenProbability: Float? = null
)

/**
 * Wraps CameraX + ML Kit face detection.
 *
 * Usage:
 *   val detector = FaceDetector(context)
 *   detector.start(lifecycleOwner)
 *   detector.faces.collect { result -> /* update robot eyes */ }
 */
@OptIn(ExperimentalGetImage::class)
class FaceDetector(private val appContext: android.content.Context) {

    /** Emits the most recent detection result, or null when no face is visible. */
    private val _faces = MutableStateFlow<FaceDetectionResult?>(null)
    val faces: StateFlow<FaceDetectionResult?> = _faces.asStateFlow()

    private val analysisExecutor = Executors.newSingleThreadExecutor()

    private val faceDetector by lazy {
        val options = FaceDetectorOptions.Builder()
            .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
            .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_ALL)
            .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_ALL)
            .setMinFaceSize(0.15f) // relative to image; ~15% minimum
            .enableTracking()      // assigns stable IDs across frames
            .build()
        FaceDetection.getClient(options)
    }

    /**
     * Bind camera + analyzer to the given lifecycle.
     */
    fun start(owner: LifecycleOwner) {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(appContext)

        cameraProviderFuture.addListener({
            val provider = cameraProviderFuture.get()

            // Front camera (selfie) — use DEFAULT_FRONT_CAMERA for clarity
            val cameraSelector = CameraSelector.DEFAULT_FRONT_CAMERA

            // Image analysis: every frame gets passed to ML Kit
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setTargetRotation(android.view.Surface.ROTATION_0)
                .build()
                .also { it.setAnalyzer(analysisExecutor, ::analyzeFrame) }

            // Unbind any existing use cases, then bind
            provider.unbindAll()
            provider.bindToLifecycle(
                owner,
                cameraSelector,
                analysis
            )
        }, ContextCompat.getMainExecutor(appContext))
    }

    private fun analyzeFrame(imageProxy: ImageProxy) {
        val mediaImage = imageProxy.image ?: run {
            imageProxy.close()
            return
        }

        val inputImage = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)

        faceDetector.process(inputImage)
            .addOnSuccessListener { faces ->
                if (faces.isNotEmpty()) {
                    val face = faces.first()
                    val result = toDetectionResult(face, imageProxy.width, imageProxy.height)
                    _faces.value = result
                } else {
                    _faces.value = null
                }
            }
            .addOnFailureListener {
                _faces.value = null
            }
            .addOnCompleteListener {
                imageProxy.close()
            }
    }

    /**
     * Convert ML Kit [Face] + image dimensions → normalized [FaceDetectionResult].
     *
     * Front camera images are displayed mirrored (the user expects it).
     * ML Kit returns coordinates in the original (un-mirrored) image space,
     * so we mirror the X coordinate to match what the user sees on screen.
     */
    private fun toDetectionResult(face: Face, imageW: Int, imageH: Int): FaceDetectionResult {
        val box = face.boundingBox

        // Center in image coordinates, then normalize.
        // Flip X for front camera mirroring.
        val rawCx = box.centerX().toFloat() / imageW
        val mirroredCx = 1f - rawCx
        val cy = box.centerY().toFloat() / imageH

        val faceWidth = box.width().toFloat() / imageW

        val smile = face.smilingProbability?.takeIf { it >= 0f }
        val eyeOpen = face.leftEyeOpenProbability?.takeIf { it >= 0f }

        return FaceDetectionResult(
            cx = mirroredCx.coerceIn(0f, 1f),
            cy = cy.coerceIn(0f, 1f),
            faceWidth = faceWidth.coerceIn(0f, 1f),
            smileProbability = smile,
            leftEyeOpenProbability = eyeOpen
        )
    }
}
