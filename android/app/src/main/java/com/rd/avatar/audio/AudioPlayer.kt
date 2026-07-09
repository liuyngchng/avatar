package com.rd.avatar.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

class AudioPlayer {

    companion object {
        const val CHANNEL_CONFIG = AudioFormat.CHANNEL_OUT_MONO
        const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
        private const val TIMEOUT_GRACE_MS = 2000L  // extra time beyond expected duration
    }

    private var activeTrack: AudioTrack? = null
    @Volatile private var isPlaying = false

    /**
     * Play PCM float audio using MODE_STREAM with chunked writes.
     * Each call creates a fresh AudioTrack, writes all data, waits for completion,
     * then stops + flushes to clear the internal buffer — ensuring no residual
     * audio bleeds into the next sentence.
     */
    suspend fun play(pcmFloats: FloatArray, sampleRate: Int = 22050) = withContext(Dispatchers.IO) {
        // Convert float → short (on IO thread to avoid blocking caller)
        val shortSamples = ShortArray(pcmFloats.size) { i ->
            (pcmFloats[i] * Short.MAX_VALUE).toInt()
                .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                .toShort()
        }

        val minBufSize = AudioTrack.getMinBufferSize(sampleRate, CHANNEL_CONFIG, AUDIO_FORMAT)
        val bufferSizeInBytes = maxOf(minBufSize, 4096)

        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANT)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AUDIO_FORMAT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(CHANNEL_CONFIG)
                    .build()
            )
            .setBufferSizeInBytes(bufferSizeInBytes)
            .setTransferMode(AudioTrack.MODE_STREAM)  // stream: feed incrementally
            .build()

        activeTrack = track
        isPlaying = true

        try {
            track.play()

            // Write in chunks so we don't overflow the internal buffer.
            // Each chunk = half the buffer size (in shorts).
            val chunkSize = maxOf(bufferSizeInBytes / 2, 1024)
            var offset = 0
            while (offset < shortSamples.size && isPlaying) {
                val remaining = shortSamples.size - offset
                val toWrite = minOf(remaining, chunkSize)
                track.write(shortSamples, offset, toWrite)
                offset += toWrite
            }

            // Wait until all written data has been played out
            val durationMs = (shortSamples.size.toLong() * 1000) / sampleRate
            val timeoutMs = durationMs + TIMEOUT_GRACE_MS
            awaitPlaybackComplete(track, shortSamples.size, sampleRate, timeoutMs)
        } finally {
            isPlaying = false
            activeTrack = null
            try { track.stop() } catch (_: Exception) {}
            track.flush()   // ← CRITICAL: clear residual audio so next sentence starts clean
            track.release()
        }
    }

    /**
     * Block until playback reaches [frameCount] (end of audio), or [timeoutMs] elapses.
     * Uses [AudioTrack.playbackHeadPosition] polling instead of a dedicated timeout thread.
     */
    private suspend fun awaitPlaybackComplete(
        track: AudioTrack,
        frameCount: Int,
        sampleRate: Int,
        timeoutMs: Long
    ) {
        try {
            withTimeout(timeoutMs) {
                // Poll playback head position every ~20ms.
                // playState check catches early errors (e.g. AudioTrack died).
                while (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
                    val headPos = track.playbackHeadPosition
                    if (headPos >= frameCount) break
                    // kotlinx.coroutines.delay is cancellable — timeout cancels it cleanly
                    kotlinx.coroutines.delay(20)
                }
            }
        } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
            // Playback exceeded expected duration — stop gracefully
        }
    }

    fun stop() {
        isPlaying = false
        activeTrack?.apply {
            if (playState == AudioTrack.PLAYSTATE_PLAYING) {
                try { stop() } catch (_: Exception) {}
            }
            flush()  // clear buffer even on manual stop
        }
    }

    fun release() {
        isPlaying = false
        activeTrack?.apply {
            try { stop() } catch (_: Exception) {}
            flush()
            release()
        }
        activeTrack = null
    }
}
