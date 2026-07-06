package com.rd.siri.config

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

sealed class ConnectionTestResult {
    object Idle : ConnectionTestResult()
    object Testing : ConnectionTestResult()
    data class Success(val message: String) : ConnectionTestResult()
    data class Failure(val error: String) : ConnectionTestResult()
}

class ConfigViewModel(application: Application) : AndroidViewModel(application) {

    private val repository = ConfigRepository(application)

    private val _config = MutableStateFlow(repository.getConfig())
    val config: StateFlow<LlmConfig?> = _config.asStateFlow()

    private val _testResult = MutableStateFlow<ConnectionTestResult>(ConnectionTestResult.Idle)
    val testResult: StateFlow<ConnectionTestResult> = _testResult.asStateFlow()

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    fun saveConfig(apiUrl: String, model: String, apiKey: String, enableSearch: Boolean = false, searchParamName: String = "enable_search") {
        val trimmedUrl = apiUrl.trim().trimEnd('/')
        val trimmedModel = model.trim()
        val trimmedKey = apiKey.trim()

        if (trimmedUrl.isBlank() || trimmedModel.isBlank() || trimmedKey.isBlank()) {
            _testResult.value = ConnectionTestResult.Failure("所有字段不能为空")
            return
        }

        if (!trimmedUrl.startsWith("http://") && !trimmedUrl.startsWith("https://")) {
            _testResult.value = ConnectionTestResult.Failure("API 地址必须以 http:// 或 https:// 开头")
            return
        }

        val newConfig = LlmConfig(trimmedUrl, trimmedModel, trimmedKey, enableSearch, searchParamName)
        repository.saveConfig(newConfig)
        _config.value = newConfig
        _testResult.value = ConnectionTestResult.Success("配置已保存")
    }

    fun testConnection(apiUrl: String, model: String, apiKey: String) {
        if (apiUrl.isBlank() || model.isBlank() || apiKey.isBlank()) {
            _testResult.value = ConnectionTestResult.Failure("请先填写完整信息")
            return
        }

        viewModelScope.launch {
            _testResult.value = ConnectionTestResult.Testing

            try {
                withContext(Dispatchers.IO) {
                    val body = JSONObject().apply {
                        put("model", model.trim())
                        put("messages", JSONArray().apply {
                            put(JSONObject().apply {
                                put("role", "user")
                                put("content", "hi")
                            })
                        })
                        put("max_tokens", 1)
                    }

                    val url = "${apiUrl.trim().trimEnd('/')}/chat/completions"
                    val request = Request.Builder()
                        .url(url)
                        .addHeader("Authorization", "Bearer ${apiKey.trim()}")
                        .addHeader("Content-Type", "application/json")
                        .post(body.toString().toRequestBody("application/json".toMediaType()))
                        .build()

                    val response = client.newCall(request).execute()

                    if (response.isSuccessful) {
                        _testResult.value = ConnectionTestResult.Success("连接成功！API 响应正常")
                    } else {
                        val errorBody = response.body?.string() ?: "未知错误"
                        _testResult.value = ConnectionTestResult.Failure(
                            "服务器返回错误 (${response.code}): ${errorBody.take(200)}"
                        )
                    }
                }
            } catch (e: java.net.UnknownHostException) {
                _testResult.value = ConnectionTestResult.Failure("无法解析地址，请检查 API 地址")
            } catch (e: java.net.ConnectException) {
                _testResult.value = ConnectionTestResult.Failure("连接被拒绝，请检查 API 地址和端口")
            } catch (e: java.net.SocketTimeoutException) {
                _testResult.value = ConnectionTestResult.Failure("连接超时，请检查网络")
            } catch (e: javax.net.ssl.SSLHandshakeException) {
                _testResult.value = ConnectionTestResult.Failure("SSL 证书验证失败")
            } catch (e: Exception) {
                _testResult.value = ConnectionTestResult.Failure("连接失败: ${e.message}")
            }
        }
    }

    fun clearConfig() {
        repository.clearConfig()
        _config.value = null
        _testResult.value = ConnectionTestResult.Idle
    }

    fun resetTestResult() {
        _testResult.value = ConnectionTestResult.Idle
    }
}
