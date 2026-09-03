package com.rd.avatar.config

import android.util.Log
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.util.concurrent.Executors

/**
 * A minimal HTTP server that lets the user configure the LLM settings from a
 * PC browser on the same LAN. Serves a small HTML form at `http://<phone-ip>:8080`
 * and persists submissions to [ConfigRepository].
 *
 * Uses a plain [ServerSocket] — no extra dependencies.
 */
class ConfigHttpServer(
    private val repository: ConfigRepository,
) {
    companion object {
        private const val TAG = "ConfigHttpServer"
        const val PORT = 8080
    }

    @Volatile
    private var serverSocket: ServerSocket? = null
    private val executor = Executors.newCachedThreadPool()

    val isRunning: Boolean get() = serverSocket != null

    /** Human-readable LAN addresses, e.g. "192.168.1.5:8080". */
    fun lanAddresses(): List<String> {
        val addrs = mutableListOf<String>()
        try {
            NetworkInterface.getNetworkInterfaces().toList().forEach { nif ->
                if (!nif.isUp || nif.isLoopback) return@forEach
                nif.inetAddresses.toList().forEach { addr ->
                    if (addr is java.net.Inet4Address && !addr.isLoopbackAddress) {
                        addrs.add("http://${addr.hostAddress}:$PORT")
                    }
                }
            }
        } catch (_: Exception) {
        }
        return addrs
    }

    fun start(): Boolean {
        if (serverSocket != null) return true
        return try {
            serverSocket = ServerSocket(PORT).also {
                executor.execute { acceptLoop(it) }
            }
            Log.i(TAG, "HTTP config server started on port $PORT")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start HTTP config server", e)
            false
        }
    }

    fun stop() {
        try { serverSocket?.close() } catch (_: Exception) {}
        serverSocket = null
        Log.i(TAG, "HTTP config server stopped")
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
                val reader = BufferedReader(InputStreamReader(sock.getInputStream()))
                val requestLine = reader.readLine() ?: return
                val parts = requestLine.split(" ")
                val method = parts.getOrNull(0) ?: ""
                val path = parts.getOrNull(1) ?: "/"

                // Read headers
                val headers = mutableMapOf<String, String>()
                while (true) {
                    val line = reader.readLine() ?: break
                    if (line.isEmpty()) break
                    val colon = line.indexOf(':')
                    if (colon > 0) headers[line.substring(0, colon).trim().lowercase()] =
                        line.substring(colon + 1).trim()
                }

                // Read body if Content-Length present
                val contentLength = headers["content-length"]?.toIntOrNull() ?: 0
                val body = if (contentLength > 0) {
                    val buf = CharArray(contentLength)
                    reader.read(buf, 0, contentLength)
                    String(buf)
                } else ""

                when (path) {
                    "/" -> serveHtml(sock)
                    "/save" -> {
                        if (method == "POST") {
                            handleSave(sock, body)
                        } else {
                            respond(sock, 405, "Method Not Allowed", "text/plain")
                        }
                    }
                    else -> respond(sock, 404, "Not Found", "text/plain")
                }
            }
        } catch (_: Exception) {
        }
    }

    private fun serveHtml(sock: Socket) {
        val cfg = repository.getConfig()
        val apiUrl = cfg?.apiUrl ?: ConfigRepository.DEFAULT_API_URL
        val model = cfg?.model ?: ConfigRepository.DEFAULT_MODEL
        val apiKey = cfg?.apiKey ?: ""
        val enableSearch = cfg?.enableSearch ?: true

        val html = """
            <!DOCTYPE html>
            <html lang="zh-CN">
            <head>
              <meta charset="UTF-8">
              <meta name="viewport" content="width=device-width, initial-scale=1.0">
              <title>小然配置</title>
              <style>
                body { font-family: -apple-system, 'PingFang SC', 'Microsoft YaHei', sans-serif; max-width: 520px; margin: 40px auto; padding: 0 20px; color: #222; }
                h1 { font-size: 24px; }
                label { display: block; margin: 16px 0 6px; font-weight: 600; }
                input[type=text], input[type=password] { width: 100%; padding: 10px; font-size: 16px; border: 1px solid #ccc; border-radius: 6px; box-sizing: border-box; }
                .hint { font-size: 13px; color: #888; margin-top: 4px; }
                button { margin-top: 24px; padding: 12px 24px; font-size: 16px; background: #4488FF; color: #fff; border: none; border-radius: 6px; cursor: pointer; }
                #result { margin-top: 16px; font-weight: 600; }
                .ok { color: #2e7d32; }
                .err { color: #c62828; }
              </style>
            </head>
            <body>
              <h1>小然 LLM 配置</h1>
              <form id="form">
                <label>API 地址</label>
                <input type="text" name="apiUrl" value="${escapeHtml(apiUrl)}">
                <div class="hint">兼容 OpenAI chat/completions 接口</div>

                <label>模型名称</label>
                <input type="text" name="model" value="${escapeHtml(model)}">

                <label>API Key</label>
                <input type="password" name="apiKey" value="${escapeHtml(apiKey)}" placeholder="sk-...">
                <div class="hint">密钥将加密存储在设备本地</div>

                <label style="font-weight: normal;">
                  <input type="checkbox" name="enableSearch" ${if (enableSearch) "checked" else ""}> 启用联网搜索
                </label>

                <button type="submit">保存配置</button>
              </form>
              <div id="result"></div>
              <script>
                document.getElementById('form').addEventListener('submit', async function(e) {
                  e.preventDefault();
                  const data = new URLSearchParams(new FormData(this));
                  const res = await fetch('/save', { method: 'POST', body: data });
                  const text = await res.text();
                  const el = document.getElementById('result');
                  if (res.ok) { el.className = 'ok'; el.textContent = '已保存'; }
                  else { el.className = 'err'; el.textContent = text; }
                });
              </script>
            </body>
            </html>
        """.trimIndent()

        respond(sock, 200, html, "text/html")
    }

    private fun handleSave(sock: Socket, body: String) {
        val params = parseForm(body)
        val apiUrl = params["apiUrl"]?.trim() ?: ""
        val model = params["model"]?.trim() ?: ""
        val apiKey = params["apiKey"]?.trim() ?: ""
        val enableSearch = params["enableSearch"] == "on"

        if (apiUrl.isBlank() || model.isBlank() || apiKey.isBlank()) {
            respond(sock, 400, "所有字段不能为空", "text/plain")
            return
        }
        if (!apiUrl.startsWith("http://") && !apiUrl.startsWith("https://")) {
            respond(sock, 400, "API 地址必须以 http:// 或 https:// 开头", "text/plain")
            return
        }

        repository.saveConfig(
            LlmConfig(apiUrl = apiUrl, model = model, apiKey = apiKey, enableSearch = enableSearch)
        )
        Log.i(TAG, "Config saved via HTTP: model=$model")
        respond(sock, 200, "OK", "text/plain")
    }

    private fun parseForm(body: String): Map<String, String> {
        val map = mutableMapOf<String, String>()
        for (pair in body.split("&")) {
            val idx = pair.indexOf('=')
            if (idx < 0) continue
            val key = URLDecoder.decode(pair.substring(0, idx), "UTF-8")
            val value = URLDecoder.decode(pair.substring(idx + 1), "UTF-8")
            map[key] = value
        }
        return map
    }

    private fun respond(sock: Socket, code: Int, body: String, contentType: String) {
        val bytes = body.toByteArray(Charsets.UTF_8)
        val header = buildString {
            appendLine("HTTP/1.1 $code ${if (code == 200) "OK" else "Error"}")
            appendLine("Content-Type: $contentType; charset=utf-8")
            appendLine("Access-Control-Allow-Origin: *")
            appendLine("Content-Length: ${bytes.size}")
            appendLine("Connection: close")
            appendLine()
        }
        sock.getOutputStream().use {
            it.write(header.toByteArray(Charsets.UTF_8))
            it.write(bytes)
            it.flush()
        }
    }

    private fun escapeHtml(s: String): String {
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace("\"", "&quot;").replace("'", "&#39;")
    }
}