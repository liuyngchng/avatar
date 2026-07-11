package com.rd.avatar.chat

import com.rd.avatar.config.ConfigRepository
import com.rd.avatar.config.LlmConfig
import com.rd.avatar.model.ChatMessage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import android.util.Log
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.util.concurrent.TimeUnit

class LlmClient(private val configRepository: ConfigRepository) {

    companion object {
        private val dateFormat = ThreadLocal.withInitial {
            java.text.SimpleDateFormat("yyyy年M月d日 EEEE", java.util.Locale.CHINESE)
        }

        private fun buildSystemPrompt(enableSearch: Boolean): String {
            val now = dateFormat.get()!!.format(java.util.Date())
            val base = "你是一个语音助手，名字叫「小火」。用简短口语化的中文回复，控制在1-3句话（80字以内）。" +
                "只回应用户说的话，不要主动提供额外信息（如日期、天气等），除非用户明确问了。" +
                "回复自然友好、直接明了，保持中性的语气。" +
                "当前日期是$now（仅当你需要判断时间时参考，不要主动报日期）。" +
                "这是一段持续的多轮对话。下面 messages 中 role=user 是人类对你说的，role=assistant 是你自己说过的。" +
                "你要记住之前聊过的话题，可以自然地引用前面说过的话。" +
                "始终保持一致的助手风格。"
            return if (enableSearch) {
                base + "你已启用联网搜索，获取到的实时信息会直接提供给你。" +
                    "对于需要最新数据的问题，务必基于搜索结果回答。" +
                    "严禁说你无法搜索或不支持联网——搜索是系统自动完成的。"
            } else {
                base + "如果用户问到你不了解的事，直接说不知道即可。"
            }
        }

        private val JSON_MEDIA_TYPE = "application/json".toMediaType()

        data class LlmParams(
            val maxTokens: Int = 512,
            val temperature: Double = 0.7,
            val topP: Double = 0.9
        )
    }

    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    private val defaultParams = LlmParams()

    suspend fun chat(
        messages: List<ChatMessage>,
        params: LlmParams = defaultParams
    ): Result<String> = withContext(Dispatchers.IO) {
        val config = loadConfig() ?: return@withContext Result.failure(
            IllegalStateException("请先在设置中配置 API 信息")
        )

        runCatching {
            val body = buildRequestBody(messages, config, params, stream = false)
            val request = buildRequest(config, body)

            val response = client.newCall(request).execute()
            if (!response.isSuccessful) {
                val errorBody = response.body?.string() ?: "未知错误"
                throw Exception("API 错误 (${response.code}): ${errorBody.take(300)}")
            }

            val json = JSONObject(response.body?.string() ?: "{}")
            json.getJSONArray("choices")
                .getJSONObject(0)
                .getJSONObject("message")
                .getString("content")
        }
    }

    fun chatStream(
        messages: List<ChatMessage>,
        params: LlmParams = defaultParams
    ): Flow<String> = flow {
        val config = loadConfig() ?: throw IllegalStateException("请先在设置中配置 API 信息")

        val body = buildRequestBody(messages, config, params, stream = true)
        val request = buildRequest(config, body)

        val response = client.newCall(request).execute()

        if (!response.isSuccessful) {
            val errorBody = response.body?.string() ?: "未知错误"
            throw Exception("API 错误 (${response.code}): ${errorBody.take(300)}")
        }

        val reader = BufferedReader(InputStreamReader(response.body?.byteStream() ?: return@flow))

        reader.useLines { lines ->
            for (line in lines) {
                if (line.startsWith("data: ")) {
                    val data = line.removePrefix("data: ").trim()
                    if (data == "[DONE]") break

                    try {
                        val json = JSONObject(data)
                        val choices = json.optJSONArray("choices")
                        if (choices != null && choices.length() > 0) {
                            val delta = choices.getJSONObject(0).optJSONObject("delta")
                            if (delta != null && delta.has("content") && !delta.isNull("content")) {
                                val content = delta.getString("content")
                                if (content.isNotEmpty()) {
                                    emit(content)
                                }
                            }
                        }
                    } catch (_: Exception) {
                    }
                }
            }
        }
    }.flowOn(Dispatchers.IO)

    private fun loadConfig(): LlmConfig? = configRepository.getConfig()

    private fun buildRequestBody(
        messages: List<ChatMessage>,
        config: LlmConfig,
        params: LlmParams,
        stream: Boolean
    ): String {
        val msgArray = JSONArray()

        msgArray.put(JSONObject().apply {
            put("role", "system")
            put("content", buildSystemPrompt(config.enableSearch))
        })

        for (msg in messages) {
            msgArray.put(JSONObject().apply {
                put("role", msg.role.value)
                put("content", msg.content)
            })
        }

        return JSONObject().apply {
            put("model", config.model)
            put("messages", msgArray)
            put("stream", stream)
            put("max_tokens", params.maxTokens)
            put("temperature", params.temperature)
            put("top_p", params.topP)
            if (config.enableSearch && config.searchParamName.isNotBlank()) {
                Log.i("LlmClient", "联网搜索已启用, param=${config.searchParamName}")
                put(config.searchParamName, true)
            }
        }.toString()
    }

    private fun buildRequest(config: LlmConfig, body: String): Request =
        Request.Builder()
            .url(config.chatCompletionsUrl)
            .addHeader("Authorization", "Bearer ${config.apiKey}")
            .addHeader("Content-Type", "application/json")
            .post(body.toRequestBody(JSON_MEDIA_TYPE))
            .build()
}
