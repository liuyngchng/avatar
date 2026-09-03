package com.rd.avatar.robot

import kotlin.random.Random

/**
 * Port of `desktop/internal/brain/viseme.go`.
 *
 * Generates the viseme timeline that drives the VRM mouth while speaking.
 * We deliberately do NOT try to align mouth shapes with the actual spoken
 * text — the Matcha-TTS engine does not expose per-phoneme timestamps, so
 * any alignment would be a rough guess. Instead we cycle through random
 * mouth shapes so the lips read as "talking".
 */

/** VRM1 viseme (mouth shape) names. */
object Visemes {
    const val AA = "aa"      // big open mouth
    const val IH = "ih"      // wide grin
    const val OU = "ou"      // rounded lips
    const val EE = "ee"      // half open
    const val OH = "oh"      // rounded wide
    const val REST = "rest"  // closed mouth
}

/** A single entry in the viseme timeline. */
data class VisemeTimelineEntry(
    val viseme: String,
    val startMs: Int,
)

/** The full viseme timeline sent to the WebView frontend. */
data class VisemeTimeline(
    val type: String = "viseme_timeline",
    val timeline: List<VisemeTimelineEntry>,
)

object VisemeGenerator {

    /** Mouth shapes we cycle through while speaking. */
    private val mouthVisemes = listOf(
        Visemes.AA, Visemes.IH, Visemes.OU, Visemes.EE, Visemes.OH,
    )

    /** Time step between viseme changes (ms). */
    private const val MOUTH_STEP_MS = 120

    /**
     * Create a viseme timeline that cycles through random mouth shapes for
     * the full audio duration. Every [MOUTH_STEP_MS] we pick a random mouth
     * shape, with a ~20% chance of a closed-mouth (rest) frame so the lips
     * open and close naturally instead of staying frozen open.
     *
     * @param audioDurationMs duration of the synthesized audio in milliseconds.
     * @return the timeline, or null if [audioDurationMs] <= 0.
     */
    fun generateVisemeTimeline(text: String, audioDurationMs: Int): VisemeTimeline? {
        if (audioDurationMs <= 0) return null

        val entries = ArrayList<VisemeTimelineEntry>(audioDurationMs / MOUTH_STEP_MS + 2)
        var currentMs = 0
        while (currentMs < audioDurationMs) {
            val viseme = if (Random.nextInt(5) == 0) {
                Visemes.REST
            } else {
                mouthVisemes[Random.nextInt(mouthVisemes.size)]
            }
            entries.add(VisemeTimelineEntry(viseme = viseme, startMs = currentMs))
            currentMs += MOUTH_STEP_MS
        }

        return VisemeTimeline(timeline = entries)
    }
}
