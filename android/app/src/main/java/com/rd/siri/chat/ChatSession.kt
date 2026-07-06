package com.rd.siri.chat

import com.rd.siri.model.ChatMessage
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

class ChatSession(
    private val llmClient: LlmClient,
    private val maxHistory: Int = 5,
    private val maxScreenMessages: Int = 20
) {

    /** Messages shown on screen — capped at [maxScreenMessages]. */
    private val _messages = MutableStateFlow<List<ChatMessage>>(emptyList())
    val messages: StateFlow<List<ChatMessage>> = _messages.asStateFlow()

    /**
     * Full LLM context buffer — preserved across screen clears.
     * Grows unboundedly; only the last [maxHistory] messages are sent to the LLM.
     */
    private val contextBuffer = mutableListOf<ChatMessage>()

    /** LLM context window: last [maxHistory] messages from the full context buffer. */
    private val contextMessages: List<ChatMessage>
        get() = contextBuffer.takeLast(maxHistory)

    /** Append a message to the on-screen list, trimming to [maxScreenMessages]. */
    private fun appendToScreen(msg: ChatMessage) {
        _messages.value = (_messages.value + msg).takeLast(maxScreenMessages)
    }

    suspend fun send(text: String): Result<String> {
        val userMsg = ChatMessage(role = ChatMessage.Role.USER, content = text)
        appendToScreen(userMsg)
        contextBuffer.add(userMsg)

        val result = llmClient.chat(contextMessages)

        result.onSuccess { reply ->
            val assistantMsg = ChatMessage(role = ChatMessage.Role.ASSISTANT, content = reply)
            appendToScreen(assistantMsg)
            contextBuffer.add(assistantMsg)
        }.onFailure {
            // Rollback both buffers on failure
            _messages.value = _messages.value.dropLast(1)
            contextBuffer.removeLast()
        }

        return result
    }

    suspend fun sendStream(text: String): Result<Flow<String>> {
        val userMsg = ChatMessage(role = ChatMessage.Role.USER, content = text)
        appendToScreen(userMsg)
        contextBuffer.add(userMsg)

        return try {
            val flow = llmClient.chatStream(contextMessages)
            Result.success(flow)
        } catch (e: Exception) {
            _messages.value = _messages.value.dropLast(1)
            contextBuffer.removeLast()
            Result.failure(e)
        }
    }

    fun appendAssistantReply(text: String) {
        if (text.isBlank()) return
        val assistantMsg = ChatMessage(role = ChatMessage.Role.ASSISTANT, content = text)
        appendToScreen(assistantMsg)
        contextBuffer.add(assistantMsg)
    }

    /** Full clear — both screen and LLM context (user-initiated). */
    fun clear() {
        _messages.value = emptyList()
        contextBuffer.clear()
    }

    val messageCount: Int
        get() = _messages.value.size
}
