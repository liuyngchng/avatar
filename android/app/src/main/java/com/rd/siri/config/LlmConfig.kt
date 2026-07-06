package com.rd.siri.config

data class LlmConfig(
    val apiUrl: String,
    val model: String,
    val apiKey: String,
    val enableSearch: Boolean = true,
    val searchParamName: String = "enable_search"
) {
    val baseUrl: String
        get() = apiUrl.trimEnd('/')

    val chatCompletionsUrl: String
        get() = "$baseUrl/chat/completions"

    val isValid: Boolean
        get() = apiUrl.isNotBlank() && model.isNotBlank() && apiKey.isNotBlank()
            && apiUrl.startsWith("http")
}
