package com.rd.avatar.webview

import android.content.Context
import android.util.Log
import java.io.IOException
import java.io.OutputStream
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors

/**
 * Tiny local HTTP server that serves the VRM assets (HTML, JS, models) from
 * the app's assets directory. Android WebView cannot load ES module scripts
 * from file:///android_asset/ (MIME type and CORS issues), so we serve them
 * over http://127.0.0.1:<port>.
 *
 * The server only accepts connections from localhost (loopback).
 */
class VrmAssetServer(private val context: Context) {

    companion object {
        private const val TAG = "VrmAssetServer"
        private const val ASSET_PREFIX = "vrm/"
    }

    @Volatile
    private var serverSocket: ServerSocket? = null
    private val executor = Executors.newCachedThreadPool()

    @Volatile
    var port: Int = 0
        private set

    val isRunning: Boolean get() = serverSocket != null

    fun start(): Boolean {
        if (serverSocket != null) return true
        return try {
            // Bind to loopback only — not accessible from LAN.
            serverSocket = ServerSocket(0, 5, java.net.InetAddress.getByName("127.0.0.1")).also {
                port = it.localPort
                executor.execute { acceptLoop(it) }
            }
            Log.i(TAG, "VRM asset server started on 127.0.0.1:$port")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start VRM asset server", e)
            false
        }
    }

    fun stop() {
        try { serverSocket?.close() } catch (_: Exception) {}
        serverSocket = null
        Log.i(TAG, "VRM asset server stopped")
    }

    private fun acceptLoop(ss: ServerSocket) {
        while (true) {
            val socket = try {
                ss.accept()
            } catch (_: Exception) {
                break
            }
            executor.execute { handle(socket) }
        }
    }

    private fun handle(socket: Socket) {
        try {
            socket.use { sock ->
                val input = sock.getInputStream()
                // Read request line.
                val sb = StringBuilder()
                var ch: Int
                while (input.read().also { ch = it } != -1) {
                    if (ch == '\r'.code) {
                        input.read() // skip \n
                        break
                    }
                    sb.append(ch.toChar())
                }
                val requestLine = sb.toString()
                val parts = requestLine.split(" ")
                val path = parts.getOrNull(1) ?: "/"

                // Read (and discard) headers.
                while (true) {
                    val line = readLine(input) ?: break
                    if (line.isEmpty()) break
                }

                val assetPath = if (path == "/" || path == "/index.html") {
                    "${ASSET_PREFIX}index.html"
                } else {
                    // Strip leading slash, prepend asset prefix.
                    val cleanPath = path.removePrefix("/")
                    "$ASSET_PREFIX$cleanPath"
                }

                try {
                    val bytes = context.assets.open(assetPath).use { it.readBytes() }
                    val mime = mimeType(assetPath)
                    respond(sock, 200, bytes, mime)
                } catch (e: IOException) {
                    // File not found — 404.
                    respond(sock, 404, "Not Found: $assetPath".toByteArray(), "text/plain")
                }
            }
        } catch (_: Exception) {
        }
    }

    private fun readLine(input: java.io.InputStream): String? {
        val sb = StringBuilder()
        var ch: Int
        while (input.read().also { ch = it } != -1) {
            if (ch == '\r'.code) {
                input.read() // skip \n
                break
            }
            sb.append(ch.toChar())
        }
        return if (sb.isEmpty() && ch == -1) null else sb.toString()
    }

    private fun respond(sock: Socket, code: Int, body: ByteArray, mime: String) {
        val header = buildString {
            appendLine("HTTP/1.1 $code ${if (code == 200) "OK" else "Not Found"}")
            appendLine("Content-Type: $mime")
            appendLine("Content-Length: ${body.size}")
            appendLine("Access-Control-Allow-Origin: *")
            appendLine("Cache-Control: no-cache")
            appendLine("Connection: close")
            appendLine()
        }
        sock.getOutputStream().use {
            it.write(header.toByteArray(Charsets.UTF_8))
            it.write(body)
            it.flush()
        }
    }

    private fun mimeType(path: String): String = when {
        path.endsWith(".html") -> "text/html; charset=utf-8"
        path.endsWith(".js")   -> "application/javascript; charset=utf-8"
        path.endsWith(".vrm")  -> "application/octet-stream"
        path.endsWith(".onnx") -> "application/octet-stream"
        path.endsWith(".wasm") -> "application/wasm"
        else                   -> "application/octet-stream"
    }
}