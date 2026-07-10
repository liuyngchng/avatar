package com.rd.avatar.camera

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * Result of face detection — normalized to screen-independent coordinates.
 */
data class FaceDetectionResult(
    val cx: Float,
    val cy: Float,
    val faceWidth: Float,
    val smileProbability: Float? = null,
    val leftEyeOpenProbability: Float? = null
)

/**
 * Camera manager — rear camera by default, supports photo capture + optional face detection.
 *
 * Usage:
 *   val camera = CameraManager(context)
 *   camera.startPreview(lifecycleOwner)      // show rear camera preview
 *   camera.capturePhoto { bitmap -> ... }    // take a photo on demand
 *   camera.stop()
 */
class FaceDetector(private val appContext: android.content.Context) {

    companion object {
        private const val TAG = "CameraManager"
    }

    private val cameraExecutor = Executors.newSingleThreadExecutor()
    private var cameraProvider: ProcessCameraProvider? = null
    private var imageCapture: ImageCapture? = null
    private var preview: Preview? = null
    private var analysis: ImageAnalysis? = null

    // Photo capture callback
    private var onPhotoCaptured: ((Bitmap) -> Unit)? = null

    /**
     * Start rear camera preview (no face tracking).
     * Call when entering LOOKING mode.
     */
    fun startPreview(owner: LifecycleOwner) {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(appContext)

        cameraProviderFuture.addListener({
            val provider = cameraProviderFuture.get()
            cameraProvider = provider

            // ── Rear camera ──
            val cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA

            // ── Preview ──
            preview = Preview.Builder().build()

            // ── Image capture (for on-demand photos) ──
            imageCapture = ImageCapture.Builder()
                .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
                .setTargetRotation(android.view.Surface.ROTATION_0)
                .build()

            // Unbind any existing use cases, then bind
            provider.unbindAll()
            provider.bindToLifecycle(
                owner,
                cameraSelector,
                preview,
                imageCapture
            )

            Log.i(TAG, "Rear camera preview started")
        }, ContextCompat.getMainExecutor(appContext))
    }

    /**
     * Capture a single photo from the rear camera.
     *
     * @param onBitmap callback with the captured bitmap (JPEG → Bitmap)
     */
    fun capturePhoto(onBitmap: (Bitmap) -> Unit) {
        val capture = imageCapture ?: run {
            Log.w(TAG, "ImageCapture not initialized — call startPreview() first")
            return
        }

        onPhotoCaptured = onBitmap

        capture.takePicture(
            cameraExecutor,
            object : ImageCapture.OnImageCapturedCallback() {
                override fun onCaptureSuccess(imageProxy: ImageProxy) {
                    val bitmap = imageProxyToBitmap(imageProxy)
                    imageProxy.close()
                    onPhotoCaptured?.invoke(bitmap)
                    onPhotoCaptured = null
                    Log.i(TAG, "Photo captured: ${bitmap.width}x${bitmap.height}")
                }

                override fun onError(exception: ImageCaptureException) {
                    Log.e(TAG, "Photo capture failed", exception)
                    onPhotoCaptured = null
                }
            }
        )
    }

    /**
     * Convert JPEG ImageProxy → Bitmap.
     */
    private fun imageProxyToBitmap(imageProxy: ImageProxy): Bitmap {
        val buffer: ByteBuffer = imageProxy.planes[0].buffer
        val bytes = ByteArray(buffer.remaining())
        buffer.get(bytes)
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
    }

    /**
     * Convert Bitmap → JPEG byte array (for sending to vision API).
     */
    fun bitmapToJpeg(bitmap: Bitmap, quality: Int = 85): ByteArray {
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, stream)
        return stream.toByteArray()
    }

    /** Stop the camera and release resources. */
    fun stop() {
        cameraProvider?.unbindAll()
        cameraProvider = null
        imageCapture = null
        preview = null
        analysis = null
        Log.i(TAG, "Camera stopped")
    }
}
