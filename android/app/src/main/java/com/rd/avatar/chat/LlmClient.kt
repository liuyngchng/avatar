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
            val base = "你是一个语音助手，名字叫「小火」。用口语化的中文回复，自然友好、直接明了。" +
                "闲聊或简单问题控制在1-3句话（80字以内）；" +
                "知识类问题可以适当展开解释，但保持简洁，不超过150字。" +
                "围绕用户的问题回答，不要偏离话题。" +
                "当前日期是$now（仅当需要判断时间时参考，不要主动报日期）。" +
                "这是一个多轮对话，记住之前聊过的话题，保持一致的语气。"
            return if (enableSearch) {
                base + "你已启用联网搜索，获取到的实时信息会直接提供给你。" +
                    "对于需要最新数据的问题，务必基于搜索结果回答。" +
                    "严禁说你无法搜索或不支持联网——搜索是系统自动完成的。"
            } else {
                base + "训练数据中有的知识可以直接回答；确实不知道的事情，诚实说明即可。"
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
