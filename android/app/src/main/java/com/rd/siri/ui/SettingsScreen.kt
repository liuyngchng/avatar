package com.rd.siri.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.rd.siri.config.ConfigViewModel
import com.rd.siri.config.ConnectionTestResult

data class LlmPreset(
    val name: String,
    val apiUrl: String,
    val model: String,
    val searchParamName: String = "enable_search"
)

val LLM_PRESETS = listOf(
    LlmPreset("阿里百炼", "https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-plus", "enable_search"),
    LlmPreset("DeepSeek", "https://api.deepseek.com/v1", "deepseek-v4-flash", ""),
    LlmPreset("硅基流动", "https://api.siliconflow.cn/v1", "deepseek-ai/DeepSeek-V3", ""),
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    viewModel: ConfigViewModel,
    onBack: () -> Unit
) {
    val config by viewModel.config.collectAsState()
    val testResult by viewModel.testResult.collectAsState()

    var apiUrl by remember { mutableStateOf(config?.apiUrl ?: "") }
    var model by remember { mutableStateOf(config?.model ?: "") }
    var apiKey by remember { mutableStateOf(config?.apiKey ?: "") }
    var searchParamName by remember { mutableStateOf(config?.searchParamName ?: "enable_search") }
    var showKey by remember { mutableStateOf(false) }
    // Load saved config on first composition
    LaunchedEffect(config) {
        config?.let {
            apiUrl = it.apiUrl
            model = it.model
            apiKey = it.apiKey
            searchParamName = it.searchParamName
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("大模型配置") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Filled.ArrowBack, contentDescription = "返回")
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            // API URL
            OutlinedTextField(
                value = apiUrl,
                onValueChange = { apiUrl = it; viewModel.resetTestResult() },
                label = { Text("API 地址") },
                placeholder = { Text("https://api.deepseek.com/v1") },
                supportingText = { Text("兼容 OpenAI chat/completions 接口") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true
            )

            // Model name
            OutlinedTextField(
                value = model,
                onValueChange = { model = it; viewModel.resetTestResult() },
                label = { Text("模型名称") },
                placeholder = { Text("deepseek-v4-flash") },
                supportingText = { Text("如 deepseek-v4-flash, gpt-4o-mini, qwen-plus 等") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true
            )

            // API Key
            OutlinedTextField(
                value = apiKey,
                onValueChange = { apiKey = it; viewModel.resetTestResult() },
                label = { Text("API Key") },
                placeholder = { Text("sk-...") },
                supportingText = { Text("密钥将加密存储在设备本地") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                visualTransformation = if (showKey) VisualTransformation.None
                else PasswordVisualTransformation(),
                trailingIcon = {
                    IconButton(onClick = { showKey = !showKey }) {
                        Icon(
                            imageVector = if (showKey) Icons.Filled.VisibilityOff
                            else Icons.Filled.Visibility,
                            contentDescription = if (showKey) "隐藏" else "显示"
                        )
                    }
                }
            )

            // Quick presets
            Text("快捷预设", style = MaterialTheme.typography.titleSmall)
            LazyRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                items(LLM_PRESETS) { preset ->
                    SuggestionChip(
                        onClick = {
                            apiUrl = preset.apiUrl
                            model = preset.model
                            searchParamName = preset.searchParamName
                            viewModel.resetTestResult()
                        },
                        label = { Text(preset.name) }
                    )
                }
            }

            // Test result
            when (val result = testResult) {
                is ConnectionTestResult.Testing -> {
                    LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                    Text("正在测试连接...", style = MaterialTheme.typography.bodySmall)
                }
                is ConnectionTestResult.Success -> {
                    Text(
                        result.message,
                        color = MaterialTheme.colorScheme.primary,
                        style = MaterialTheme.typography.bodySmall
                    )
                }
                is ConnectionTestResult.Failure -> {
                    Text(
                        result.error,
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall
                    )
                }
                ConnectionTestResult.Idle -> { /* nothing */ }
            }

            Spacer(modifier = Modifier.weight(1f))

            // Action buttons
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                OutlinedButton(
                    onClick = {
                        viewModel.clearConfig()
                        apiUrl = ""
                        model = ""
                        apiKey = ""
                    },
                    modifier = Modifier.weight(1f)
                ) { Text("清空") }

                OutlinedButton(
                    onClick = { viewModel.testConnection(apiUrl, model, apiKey) },
                    modifier = Modifier.weight(1f)
                ) { Text("测试连接") }

                Button(
                    onClick = { viewModel.saveConfig(apiUrl, model, apiKey, true, searchParamName) },
                    modifier = Modifier.weight(1f)
                ) { Text("保存") }
            }
        }
    }
}
