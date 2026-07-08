package com.rd.avatar.model

import android.content.Context
import android.net.Uri
import android.os.Build
import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.util.concurrent.TimeUnit
import java.util.zip.ZipInputStream

object ModelManager {
    private const val TAG = "RobotCompanion"

    private const val NATIVE_LIB_DIR = "lib"
    private const val NATIVE_LIB = "libsherpa-onnx.so"
    const val ASR_MODEL_DIR = "asr"
    const val TTS_MODEL_DIR = "tts"
    const val KWS_MODEL_DIR = "kws"

    private val ASR_REQUIRED = listOf("model.int8.onnx", "tokens.txt")
    private val TTS_REQUIRED = listOf("model.onnx", "vocos.onnx", "tokens.txt", "lexicon.txt")
    private val KWS_REQUIRED = listOf("encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt")

    // Normalize well-known file names after extraction
    private val RENAME_MAP = mapOf(
        "model-steps-3.onnx" to "model.onnx",
        "vocos-22khz-univ.onnx" to "vocos.onnx",
        // KWS model: use standard short names
        "encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx" to "encoder.onnx",
        "decoder-epoch-12-avg-2-chunk-16-left-64.onnx" to "decoder.onnx",
        "joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx" to "joiner.onnx",
    )

    // Download URLs
    private const val ASR_DOWNLOAD_URL =
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2"
    private const val TTS_DOWNLOAD_URL =
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/matcha-icefall-zh-baker.tar.bz2"
    private const val VOCODER_DOWNLOAD_URL =
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/vocoder-models/vocos-22khz-univ.onnx"
    private const val KWS_DOWNLOAD_URL =
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01.tar.bz2"

    private val downloadClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(5, TimeUnit.MINUTES)
        .followRedirects(true)
        .build()

    private fun modelsDir(context: Context) = File(context.filesDir, "models")
    private fun libDir(context: Context) = File(context.filesDir, NATIVE_LIB_DIR)

    fun checkAllReady(context: Context): Boolean =
        checkAsrReady(context) && checkTtsReady(context)

    fun checkNativeLibReady(context: Context): Boolean =
        File(libDir(context), NATIVE_LIB).exists()

    fun checkAsrReady(context: Context): Boolean =
        ASR_REQUIRED.all { File(modelsDir(context), "$ASR_MODEL_DIR/$it").exists() }

    fun checkTtsReady(context: Context): Boolean =
        TTS_REQUIRED.all { File(modelsDir(context), "$TTS_MODEL_DIR/$it").exists() }

    // Check if TTS tar has been extracted (at least tokens + lexicon exist)
    fun checkTtsExtracted(context: Context): Boolean =
        listOf("tokens.txt", "lexicon.txt").all {
            File(modelsDir(context), "$TTS_MODEL_DIR/$it").exists()
        }

    fun checkVocoderReady(context: Context): Boolean =
        File(modelsDir(context), "$TTS_MODEL_DIR/vocos.onnx").exists()

    fun checkKwsReady(context: Context): Boolean =
        KWS_REQUIRED.all { File(modelsDir(context), "$KWS_MODEL_DIR/$it").exists() }

    fun downloadAndExtractKws(context: Context, onProgress: (Float) -> Unit): Result<Unit> {
        return try {
            val tmpFile = File(context.cacheDir, "kws_model.tar.bz2")
            Log.i(TAG, "Downloading KWS model from $KWS_DOWNLOAD_URL")
            downloadFile(KWS_DOWNLOAD_URL, tmpFile) { p -> onProgress(p * 0.5f) }

            Log.i(TAG, "Extracting KWS model from bzip2 tar")
            tmpFile.inputStream().use { fileIn ->
                BZip2CompressorInputStream(fileIn).use { bz2 ->
                    extractTarStream(context, bz2, KWS_MODEL_DIR, -1) { p ->
                        onProgress(0.5f + p * 0.5f)
                    }
                }
            }
            tmpFile.delete()
            Log.i(TAG, "KWS download + extract complete")
            Result.success(Unit)
        } catch (e: Exception) {
            Log.e(TAG, "KWS download + extract failed", e)
            Result.failure(e)
        }
    }

    fun getNativeLibPath(context: Context): String? {
        val f = File(libDir(context), NATIVE_LIB)
        return if (f.exists()) f.absolutePath else null
    }

    fun extractAar(context: Context, uri: Uri, onProgress: (Float) -> Unit): Result<Unit> {
        return try {
            val abi = Build.SUPPORTED_ABIS[0] // e.g. "arm64-v8a"
            val targetEntry = "jni/$abi/$NATIVE_LIB"
            Log.i(TAG, "Extracting AAR for ABI=$abi, looking for $targetEntry")

            val totalSize = getSize(context, uri)
            var bytesRead = 0L

            context.contentResolver.openInputStream(uri)?.use outer@{ input ->
                ZipInputStream(input).use { zis ->
                    var entry = zis.nextEntry
                    while (entry != null) {
                        if (entry.name == targetEntry) {
                            val destDir = libDir(context)
                            destDir.mkdirs()
                            val destFile = File(destDir, NATIVE_LIB)
                            FileOutputStream(destFile).use { fos ->
                                val buf = ByteArray(8192)
                                var len: Int
                                while (zis.read(buf).also { len = it } != -1) {
                                    fos.write(buf, 0, len)
                                    bytesRead += len
                                    if (totalSize > 0) onProgress(bytesRead.toFloat() / totalSize)
                                }
                            }
                            Log.i(TAG, "AAR: extracted $NATIVE_LIB to ${destFile.absolutePath}")
                            return@outer Result.success(Unit)
                        }
                        zis.closeEntry()
                        entry = zis.nextEntry
                    }
                }
            } ?: return Result.failure(Exception("无法打开文件"))

            Result.failure(Exception("AAR 中未找到 $targetEntry，请确认文件正确"))
        } catch (e: Exception) {
            Log.e(TAG, "AAR extraction failed", e)
            Result.failure(e)
        }
    }

    fun extractTar(
        context: Context,
        uri: Uri,
        destSubDir: String,
        onProgress: (Float) -> Unit
    ): Result<Unit> {
        return try {
            val totalSize = getSize(context, uri)
            context.contentResolver.openInputStream(uri)?.use { rawInput ->
                // Wrap ONCE in BufferedInputStream for mark/reset support.
                // isBzip2Stream will peek and reset, so the same stream can
                // be reused for decompression/extraction without data loss.
                val input = java.io.BufferedInputStream(rawInput)
                val wrapped = if (isBzip2Stream(input)) {
                    Log.i(TAG, "Tar: detected bzip2 compression, auto-decompressing")
                    BZip2CompressorInputStream(input)
                } else {
                    input
                }
                extractTarStream(context, wrapped, destSubDir, totalSize, onProgress)
            } ?: Result.failure(Exception("无法打开文件"))
        } catch (e: Exception) {
            Log.e(TAG, "Tar extraction to $destSubDir failed", e)
            Result.failure(e)
        }
    }

    fun copyVocoder(
        context: Context,
        uri: Uri,
        onProgress: (Float) -> Unit
    ): Result<Unit> {
        return try {
            val destDir = File(modelsDir(context), TTS_MODEL_DIR)
            destDir.mkdirs()
            val totalSize = getSize(context, uri)
            var bytesRead = 0L
            val destFile = File(destDir, "vocos.onnx")

            context.contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(destFile).use { fos ->
                    val buf = ByteArray(8192)
                    var len: Int
                    while (input.read(buf).also { len = it } != -1) {
                        fos.write(buf, 0, len)
                        bytesRead += len
                        if (totalSize > 0) onProgress(bytesRead.toFloat() / totalSize)
                    }
                }
            } ?: return Result.failure(Exception("无法打开文件"))

            Log.i(TAG, "Vocoder copied to ${destFile.absolutePath}")
            Result.success(Unit)
        } catch (e: Exception) {
            Log.e(TAG, "Vocoder copy failed", e)
            Result.failure(e)
        }
    }

    // ---- Download methods ----

    fun downloadAndExtractAsr(context: Context, onProgress: (Float) -> Unit): Result<Unit> {
        return try {
            val tmpFile = File(context.cacheDir, "asr_model.tar.bz2")
            Log.i(TAG, "Downloading ASR model from $ASR_DOWNLOAD_URL")
            downloadFile(ASR_DOWNLOAD_URL, tmpFile) { p -> onProgress(p * 0.5f) }

            Log.i(TAG, "Extracting ASR model from bzip2 tar")
            tmpFile.inputStream().use { fileIn ->
                BZip2CompressorInputStream(fileIn).use { bz2 ->
                    extractTarStream(context, bz2, ASR_MODEL_DIR, -1) { p ->
                        onProgress(0.5f + p * 0.5f)
                    }
                }
            }
            tmpFile.delete()
            Log.i(TAG, "ASR download + extract complete")
            Result.success(Unit)
        } catch (e: Exception) {
            Log.e(TAG, "ASR download + extract failed", e)
            Result.failure(e)
        }
    }

    fun downloadAndExtractTts(context: Context, onProgress: (Float) -> Unit): Result<Unit> {
        return try {
            val tmpFile = File(context.cacheDir, "tts_model.tar.bz2")
            Log.i(TAG, "Downloading TTS model from $TTS_DOWNLOAD_URL")
            downloadFile(TTS_DOWNLOAD_URL, tmpFile) { p -> onProgress(p * 0.5f) }

            Log.i(TAG, "Extracting TTS model from bzip2 tar")
            tmpFile.inputStream().use { fileIn ->
                BZip2CompressorInputStream(fileIn).use { bz2 ->
                    extractTarStream(context, bz2, TTS_MODEL_DIR, -1) { p ->
                        onProgress(0.5f + p * 0.5f)
                    }
                }
            }
            tmpFile.delete()

            Log.i(TAG, "TTS download + extract complete")
            Result.success(Unit)
        } catch (e: Exception) {
            Log.e(TAG, "TTS download + extract failed", e)
            Result.failure(e)
        }
    }

    fun downloadVocoder(context: Context, onProgress: (Float) -> Unit): Result<Unit> {
        return try {
            downloadAndCopyVocoder(context, onProgress)
        } catch (e: Exception) {
            Log.e(TAG, "Vocoder download failed", e)
            Result.failure(e)
        }
    }

    // ---- Private helpers ----

    private fun downloadAndCopyVocoder(context: Context, onProgress: (Float) -> Unit): Result<Unit> {
        return try {
            val tmpFile = File(context.cacheDir, "vocos-22khz-univ.onnx")
            downloadFile(VOCODER_DOWNLOAD_URL, tmpFile) { p -> onProgress(p * 0.8f) }

            val destDir = File(modelsDir(context), TTS_MODEL_DIR)
            destDir.mkdirs()
            val destFile = File(destDir, "vocos.onnx")
            tmpFile.copyTo(destFile, overwrite = true)
            tmpFile.delete()

            Log.i(TAG, "Vocoder downloaded to ${destFile.absolutePath}")
            onProgress(1f)
            Result.success(Unit)
        } catch (e: Exception) {
            Log.e(TAG, "Vocoder download failed", e)
            Result.failure(e)
        }
    }

    private fun downloadFile(url: String, dest: File, onProgress: (Float) -> Unit) {
        val request = Request.Builder().url(url).build()
        downloadClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw Exception("下载失败: HTTP ${response.code}")
            val body = response.body ?: throw Exception("响应为空")
            val total = body.contentLength()
            var downloaded = 0L
            dest.parentFile?.mkdirs()
            body.byteStream().use { input ->
                FileOutputStream(dest).use { output ->
                    val buf = ByteArray(8192)
                    var len: Int
                    while (input.read(buf).also { len = it } != -1) {
                        output.write(buf, 0, len)
                        downloaded += len
                        if (total > 0) onProgress(downloaded.toFloat() / total)
                    }
                }
            }
        }
    }

    private fun extractTarStream(
        context: Context,
        inputStream: InputStream,
        destSubDir: String,
        totalSize: Long,
        onProgress: (Float) -> Unit
    ): Result<Unit> {
        return try {
            val destDir = File(modelsDir(context), destSubDir)
            destDir.mkdirs()

            var bytesRead = 0L

            TarArchiveInputStream(inputStream).use { tar ->
                var entry = tar.nextEntry
                while (entry != null) {
                    if (!entry.isDirectory) {
                        // Strip top-level directory (--strip-components=1)
                        var name = entry.name.removePrefix("./")
                        val slashIdx = name.indexOf('/')
                        name = if (slashIdx >= 0) name.substring(slashIdx + 1) else name
                        if (name.isEmpty()) {
                            entry = tar.nextEntry
                            continue
                        }

                        val destFile = File(destDir, name)
                        destFile.parentFile?.mkdirs()
                        FileOutputStream(destFile).use { fos ->
                            val buf = ByteArray(8192)
                            var len: Int
                            while (tar.read(buf).also { len = it } != -1) {
                                fos.write(buf, 0, len)
                                bytesRead += len
                                if (totalSize > 0) onProgress(bytesRead.toFloat() / totalSize)
                            }
                        }
                        Log.d(TAG, "Tar: extracted $name to $destSubDir/")
                    }
                    entry = tar.nextEntry
                }
            }

            // Normalize well-known file names
            for ((oldName, newName) in RENAME_MAP) {
                val src = File(destDir, oldName)
                val dst = File(destDir, newName)
                if (src.exists() && !dst.exists()) {
                    src.renameTo(dst)
                    Log.i(TAG, "Tar: renamed $oldName -> $newName in $destSubDir")
                }
            }

            Log.i(TAG, "Tar extraction to $destSubDir complete")
            Result.success(Unit)
        } catch (e: Exception) {
            Log.e(TAG, "Tar extraction to $destSubDir failed", e)
            Result.failure(e)
        }
    }

    /**
     * Peek at the first 3 bytes of the stream to detect bzip2 magic ("BZh").
     * The stream must support mark/reset (caller should wrap with
     * [java.io.BufferedInputStream] before passing).
     */
    private fun isBzip2Stream(input: InputStream): Boolean {
        return try {
            input.mark(3)
            val magic = ByteArray(3)
            val n = input.read(magic)
            input.reset()
            n == 3 && magic[0] == 'B'.code.toByte() && magic[1] == 'Z'.code.toByte() && magic[2] == 'h'.code.toByte()
        } catch (_: Exception) {
            false
        }
    }

    private fun getSize(context: Context, uri: Uri): Long {
        return try {
            context.contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: -1L
        } catch (e: Exception) {
            -1L
        }
    }
}
