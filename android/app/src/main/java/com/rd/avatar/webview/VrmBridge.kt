package com.rd.avatar.webview

import android.webkit.JavascriptInterface
import android.util.Log
import com.rd.avatar.robot.VisemeTimeline
import org.json.JSONObject
import org.json.JSONArray

/**
 * JavaScript bridge for the VRM WebView.
 *
 * Protocol matches the desktop `handleMessage` / `sendEvent` convention:
 *   - Kotlin → JS: `window.handleMessage(jsonString)`
 *   - JS → Kotlin: `VrmBridge.handleMessage(jsonString)` via @JavascriptInterface
 */
class VrmBridge(
    private val onEvent: (type: String, data: String?) -> Unit,
) {

    companion object {
        private const val TAG = "VrmBridge"
    }

    /** Called by JS when the VRM model has finished loading (or failed). */
    @Volatile
    var onVrmReady: (() -> Unit)? = null

    /**
     * Called by JS when the user taps the avatar or presses a key.
     * JSON format: `{"type": "tap", "data": {...}}`
     */
    @JavascriptInterface
    fun handleMessage(json: String) {
        try {
            val obj = JSONObject(json)
            val type = obj.optString("type", "")
            val data = obj.optString("data", null)
            Log.d(TAG, "Received from JS: type=$type")
            if (type == "vrm_ready") {
                onVrmReady?.invoke()
            }
            onEvent(type, data)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse JS message: $json", e)
        }
    }

    /**
     * Push state to JS. Format matches the desktop Go brain.State:
     *   {"mode": "idle", "emotion": "neutral", "isSpeaking": false, "speakingText": ""}
     */
    fun pushState(json: String): String {
        return "if(window.handleMessage)handleMessage('${escapeJs(json)}')"
    }

    /**
     * Push a viseme timeline to JS.
     * JSON format: `{"type": "viseme_timeline", "timeline": [...]}`
     */
    fun pushVisemeTimeline(json: String): String {
        return "if(window.handleMessage)handleMessage('${escapeJs(json)}')"
    }

    /**
     * Build a state JSON string matching the desktop brain.State format.
     */
    fun buildStateJson(
        mode: String,
        emotion: String,
        isSpeaking: Boolean,
        speakingText: String?,
    ): String {
        return JSONObject().apply {
            put("mode", mode)
            put("emotion", emotion)
            put("isSpeaking", isSpeaking)
            put("speakingText", speakingText ?: "")
        }.toString()
    }

    /**
     * Build a viseme timeline JSON string.
     */
    fun buildTimelineJson(timeline: VisemeTimeline): String {
        val arr = JSONArray()
        for (entry in timeline.timeline) {
            arr.put(JSONObject().apply {
                put("viseme", entry.viseme)
                put("startMs", entry.startMs)
            })
        }
        return JSONObject().apply {
            put("type", "viseme_timeline")
            put("timeline", arr)
        }.toString()
    }

    /**
     * Escape a string for safe embedding in a single-quoted JS string literal.
     */
    private fun escapeJs(s: String): String {
        return s.replace("\\", "\\\\")
            .replace("'", "\\'")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
    }
}