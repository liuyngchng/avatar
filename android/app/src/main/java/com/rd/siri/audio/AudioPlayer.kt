package com.rd.siri.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume

class AudioPlayer {

    companion object {
        const val CHANNEL_CONFIG = AudioFormat.CHANNEL_OUT_MONO
        const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
    }

    private var activeTrack: AudioTrack? = null
    private var isPlaying = false

    /**
     * Play PCM float audio. Creates a fresh AudioTrack per sentence.
     */
    suspend fun play(pcmFloats: FloatArray, sampleRate: Int = 22050) = withContext(Dispatchers.IO) {
        val shortSamples = ShortArray(pcmFloats.size) { i ->
            (pcmFloats[i] * Short.MAX_VALUE).toInt()
                .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                .toShort()
        }

        val bufferSizeInBytes = maxOf(
            shortSamples.size * 2,
            AudioTrack.getMinBufferSize(sampleRate, CHANNEL_CONFIG, AUDIO_FORMAT)
        )

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
            .setTransferMode(AudioTrack.MODE_STATIC)
            .build()

        activeTrack = track
        isPlaying = true

        try {
            track.write(shortSamples, 0, shortSamples.size)
            track.play()
            awaitPlaybackComplete(track, shortSamples.size, sampleRate)
        } finally {
            isPlaying = false
            activeTrack = null
            track.release()
        }
    }

    /**
     * Wait for playback to complete using [AudioTrack.setPlaybackPositionUpdateListener].
     * Falls back to a duration-based timeout if the listener doesn't fire.
     */
    private suspend fun awaitPlaybackComplete(
        track: AudioTrack,
        frameCount: Int,
        sampleRate: Int
    ) = suspendCancellableCoroutine<Unit> { cont ->
        val durationMs = (frameCount.toLong() * 1000) / sampleRate
        val timeoutMs = durationMs + 1000

        track.setPlaybackPositionUpdateListener(
            object : AudioTrack.OnPlaybackPositionUpdateListener {
                override fun onMarkerReached(track: AudioTrack) {
                    if (cont.isActive) cont.resume(Unit)
                }

                override fun onPeriodicNotification(track: AudioTrack) {}
            }
        )

        // Set marker at end of audio data
        track.notificationMarkerPosition = frameCount

        // Timeout guard: if the listener doesn't fire, resume after expected duration + 1s.
        // Daemon thread so it won't block JVM shutdown.
        val timeoutThread = Thread({
            try {
                Thread.sleep(timeoutMs)
            } catch (_: InterruptedException) {
                return@Thread
            }
            if (cont.isActive) {
                try { track.stop() } catch (_: Exception) {}
                cont.resume(Unit)
            }
        }, "AudioPlayTimeout").apply { isDaemon = true }
        timeoutThread.start()

        cont.invokeOnCancellation {
            timeoutThread.interrupt()
            track.setPlaybackPositionUpdateListener(null)
            try { track.stop() } catch (_: Exception) {}
        }
    }

    fun stop() {
        isPlaying = false
        activeTrack?.apply {
            setPlaybackPositionUpdateListener(null)
            if (playState == AudioTrack.PLAYSTATE_PLAYING) {
                stop()
            }
        }
    }

    fun release() {
        isPlaying = false
        activeTrack?.apply {
            setPlaybackPositionUpdateListener(null)
            release()
        }
        activeTrack = null
    }
}
