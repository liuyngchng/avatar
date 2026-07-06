package com.rd.siri.config

import android.content.Context
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

class ConfigRepository(context: Context) {

    companion object {
        private const val TAG = "RobotCompanion"
        private const val PREFS_NAME = "llm_config"
        private const val KEY_API_URL = "api_url"
        private const val KEY_MODEL = "model"
        private const val KEY_API_KEY = "api_key"
        private const val KEY_ENABLE_SEARCH = "enable_search"
        private const val KEY_SEARCH_PARAM_NAME = "search_param_name"
    }

    private val prefs = run {
        Log.d(TAG, "ConfigRepository: creating EncryptedSharedPreferences")
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            PREFS_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    fun getConfig(): LlmConfig? {
        val url = prefs.getString(KEY_API_URL, null) ?: return null
        val model = prefs.getString(KEY_MODEL, null) ?: return null
        val key = prefs.getString(KEY_API_KEY, null) ?: return null
        val enableSearch = prefs.getBoolean(KEY_ENABLE_SEARCH, true)
        val searchParamName = prefs.getString(KEY_SEARCH_PARAM_NAME, "enable_search") ?: "enable_search"
        if (url.isBlank() || model.isBlank() || key.isBlank()) return null
        return LlmConfig(apiUrl = url, model = model, apiKey = key, enableSearch = enableSearch, searchParamName = searchParamName)
    }

    fun saveConfig(config: LlmConfig) {
        prefs.edit()
            .putString(KEY_API_URL, config.apiUrl.trimEnd('/'))
            .putString(KEY_MODEL, config.model.trim())
            .putString(KEY_API_KEY, config.apiKey.trim())
            .putBoolean(KEY_ENABLE_SEARCH, config.enableSearch)
            .putString(KEY_SEARCH_PARAM_NAME, config.searchParamName)
            .apply()
    }

    fun clearConfig() {
        prefs.edit().clear().apply()
    }

    val hasConfig: Boolean
        get() = getConfig() != null
}
