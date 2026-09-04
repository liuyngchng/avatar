package com.rd.avatar.ui

import android.annotation.SuppressLint
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.rd.avatar.R
import com.rd.avatar.robot.Emotion
import com.rd.avatar.robot.RobotMode
import com.rd.avatar.robot.RobotState
import com.rd.avatar.robot.VisemeTimeline
import com.rd.avatar.webview.VrmAssetServer
import com.rd.avatar.webview.VrmBridge

/**
 * VRM 3D digital human screen backed by a WebView.
 *
 * Renders `assets/vrm/index.html` (three.js + three-vrm) and drives it via a
 * [VrmController] owned by the caller. The Kotlin side pushes mode/emotion/
 * speaking state and viseme timelines through the controller; the JS side
 * sends back tap events.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun VrmFaceScreen(
    state: RobotState,
    controller: VrmController,
    onTap: () -> Unit = {},
    onSettingsClick: () -> Unit = {},
    wakeWordEnabled: Boolean = false,
    onToggleWakeWord: () -> Unit = {},
    enginesReady: Boolean = true,
    loadingStatus: String = "",
    vrmReady: Boolean = false,
    onVrmReady: (() -> Unit)? = null,
) {
    // Keep the controller's tap handler wired to the latest onTap lambda.
    controller.onTap = onTap
    controller.bridge.onVrmReady = onVrmReady

    // Push state changes to the WebView whenever the RobotState changes.
    LaunchedEffect(state.mode, state.emotion, state.isSpeaking, state.responseText) {
        controller.sendState(
            mode = state.mode.toVrmMode(),
            emotion = state.emotion.toVrmEmotion(),
            isSpeaking = state.isSpeaking,
            speakingText = state.responseText,
        )
    }

    Box(modifier = Modifier.fillMaxSize()) {
        // Holds the server created by the factory so onRelease stops exactly
        // this AndroidView instance's server (avoids stopping a newer one).
        val serverHolder = remember { arrayOfNulls<VrmAssetServer>(1) }

        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { context ->
                // Start a local HTTP server to serve the VRM assets.
                // file:///android_asset/ breaks ES module scripts in WebView.
                val assetServer = VrmAssetServer(context)
                assetServer.start()
                serverHolder[0] = assetServer
                controller.assetServer = assetServer

                WebView(context).apply {
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.allowFileAccess = true
                    settings.allowFileAccessFromFileURLs = true
                    settings.mediaPlaybackRequiresUserGesture = false
                    webViewClient = WebViewClient()
                    webChromeClient = WebChromeClient()
                    addJavascriptInterface(controller.bridge, "VrmBridge")
                    controller.attachWebView(this)
                    loadUrl("http://127.0.0.1:${assetServer.port}/index.html")
                }
            },
            onRelease = { view ->
                // Stop the local asset server and detach the WebView so
                // navigating away and back doesn't leak servers/sockets.
                controller.detachWebView(view)
                val server = serverHolder[0]
                serverHolder[0] = null
                server?.stop()
                if (controller.assetServer === server) controller.assetServer = null
            },
        )

        // Loading overlay with detailed status (ASR/TTS/VRM stages).
        if (loadingStatus.isNotEmpty()) {
            Column(
                modifier = Modifier
                    .align(Alignment.Center)
                    .clip(RoundedCornerShape(16.dp))
                    .background(Color(0xCC1A1A2E))
                    .padding(horizontal = 24.dp, vertical = 20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                CircularProgressIndicator(color = Color.White, modifier = Modifier.size(32.dp))
                Spacer(modifier = Modifier.height(12.dp))
                Text(
                    text = loadingStatus,
                    color = Color.White.copy(alpha = 0.9f),
                    fontSize = 15.sp,
                    textAlign = TextAlign.Center,
                )
            }
        }

        // Status text below the figure. Only show when fully loaded.
        // WebView handles LISTENING/THINKING/SPEAKING status display,
        // so we only show the "waking up" message here.
        val statusText = if (loadingStatus.isNotEmpty()) {
            ""
        } else if (!enginesReady) {
            "小然正在醒来..."
        } else {
            ""
        }
        if (statusText.isNotEmpty()) {
            Text(
                text = statusText,
                color = Color.White.copy(alpha = 0.7f),
                maxLines = 2,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(horizontal = 40.dp)
                    .padding(bottom = 40.dp)
            )
        }

        // Top overlay: ear (wake word) + gear (settings)
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 12.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.End,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onToggleWakeWord) {
                Icon(
                    painter = painterResource(
                        id = if (wakeWordEnabled) R.drawable.ic_ear_fill
                        else R.drawable.ic_ear
                    ),
                    contentDescription = if (wakeWordEnabled) "关闭唤醒词" else "开启唤醒词",
                    tint = if (wakeWordEnabled) Color(0xFF4488FF)
                    else Color.White.copy(alpha = 0.55f),
                    modifier = Modifier.size(44.dp),
                )
            }
            Spacer(modifier = Modifier.width(2.dp))
            IconButton(onClick = onSettingsClick) {
                Icon(
                    imageVector = Icons.Filled.Settings,
                    contentDescription = "设置",
                    tint = Color.White.copy(alpha = 0.6f),
                    modifier = Modifier.size(44.dp),
                )
            }
        }
    }
}

/**
 * Controller bridging MainActivity ↔ the VRM WebView.
 *
 * MainActivity holds one instance and calls [sendState] / [sendVisemeTimeline].
 * The WebView (created inside [VrmFaceScreen]) is attached via [attachWebView];
 * messages sent before attachment are buffered.
 */
class VrmController(
    onTap: () -> Unit,
) {
    /** Tap handler, updated by [VrmFaceScreen] each composition so it always
     *  captures the latest MainActivity state. */
    @Volatile
    var onTap: () -> Unit = onTap

    val bridge = VrmBridge(onEvent = { type, _ ->
        if (type == "tap") onTap()
    })

    /** Local HTTP server serving VRM assets. Set by [VrmFaceScreen] factory. */
    @Volatile
    var assetServer: VrmAssetServer? = null

    @Volatile
    private var webView: WebView? = null

    /** Buffered messages sent before the WebView was ready. */
    private val pending = java.util.concurrent.ConcurrentLinkedQueue<String>()

    fun attachWebView(view: WebView) {
        webView = view
        // Flush anything that arrived before the WebView existed.
        while (true) {
            val js = pending.poll() ?: break
            view.evaluateJavascript(js, null)
        }
    }

    /** Detach the given WebView if it is the currently attached one. */
    fun detachWebView(view: WebView) {
        if (webView === view) {
            webView = null
        }
    }

    fun sendState(mode: String, emotion: String, isSpeaking: Boolean, speakingText: String?) {
        val js = bridge.pushState(
            bridge.buildStateJson(mode, emotion, isSpeaking, speakingText)
        )
        dispatch(js)
    }

    fun sendVisemeTimeline(timeline: VisemeTimeline) {
        val js = bridge.pushVisemeTimeline(bridge.buildTimelineJson(timeline))
        dispatch(js)
    }

    private fun dispatch(js: String) {
        val view = webView
        if (view != null) {
            view.post { view.evaluateJavascript(js, null) }
        } else {
            // WebView not ready yet — buffer (bounded to avoid unbounded growth).
            if (pending.size < 64) pending.add(js)
        }
    }
}

/** Map Android RobotMode → the string the JS frontend expects. */
private fun RobotMode.toVrmMode(): String = when (this) {
    RobotMode.IDLE      -> "idle"
    RobotMode.LISTENING -> "listening"
    RobotMode.SPEAKING  -> "speaking"
    RobotMode.THINKING  -> "thinking"
    RobotMode.LOOKING   -> "idle" // LOOKING has no VRM equivalent; fall back to idle
}

/** Map Android Emotion → the string the JS frontend expects. */
private fun Emotion.toVrmEmotion(): String = when (this) {
    Emotion.NEUTRAL    -> "neutral"
    Emotion.HAPPY      -> "happy"
    Emotion.CURIOUS    -> "neutral"
    Emotion.SURPRISED  -> "surprised"
    Emotion.SHY        -> "relaxed"
    Emotion.SLEEPY     -> "relaxed"
    Emotion.SAD        -> "sad"
    Emotion.GOOFY      -> "happy"
}
