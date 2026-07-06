package com.rd.siri.model

import java.util.UUID

data class ChatMessage(
    val id: String = UUID.randomUUID().toString(),
    val role: Role,
    val content: String,
    val timestamp: Long = System.currentTimeMillis()
) {
    enum class Role(val value: String) {
        USER("user"),
        ASSISTANT("assistant"),
        SYSTEM("system");

        companion object {
            fun fromValue(value: String): Role =
                entries.firstOrNull { it.value == value } ?: USER
        }
    }
}
