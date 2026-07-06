package com.rd.siri.ui

import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.BatteryAlert
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.VoiceOverOff
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.RecordVoiceOver
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsHubScreen(
    onNavigateToLlmConfig: () -> Unit,
    onNavigateToModelSetup: () -> Unit,
    onDismiss: () -> Unit,
    wakeWordEnabled: Boolean = false,
    onToggleWakeWord: (Boolean) -> Unit = {}
) {
    val context = LocalContext.current
    val powerManager = remember { context.getSystemService(android.content.Context.POWER_SERVICE) as PowerManager }
    val batteryOptimized = remember {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            !powerManager.isIgnoringBatteryOptimizations(context.packageName)
        } else false
    }
    var showBatteryWarning by remember(wakeWordEnabled, batteryOptimized) {
        mutableStateOf(wakeWordEnabled && batteryOptimized)
    }

    val appVersion = remember {
        try {
            @Suppress("DEPRECATION")
            val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
            val buildTime = packageInfo.lastUpdateTime
            val fmt = SimpleDateFormat("yyyyMMdd.HHmm", Locale.getDefault())
            "1.0.0 (${fmt.format(Date(buildTime))})"
        } catch (e: Exception) {
            "1.0.0"
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("设置") },
                navigationIcon = {
                    IconButton(onClick = onDismiss) {
                        Icon(Icons.Filled.ArrowBack, contentDescription = "返回")
                    }
                }
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(vertical = 8.dp)
        ) {
            // Section: 配置
            item(key = "header_config") {
                SectionHeader("配置")
            }
            item(key = "llm_config") {
                SettingsRow(
                    icon = Icons.Filled.Settings,
                    title = "大模型 API",
                    subtitle = "API 地址、模型名称、密钥",
                    onClick = onNavigateToLlmConfig
                )
            }

            // Section: 模型
            item(key = "header_models") {
                SectionHeader("模型")
            }
            item(key = "voice_models") {
                SettingsRow(
                    icon = Icons.Filled.Mic,
                    title = "语音模型",
                    subtitle = "ASR、TTS 等模型管理",
                    onClick = onNavigateToModelSetup
                )
            }

            // Section: 交互
            item(key = "header_interaction") {
                SectionHeader("交互")
            }
            item(key = "wake_word") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        if (wakeWordEnabled) Icons.Filled.RecordVoiceOver
                        else Icons.Filled.VoiceOverOff,
                        contentDescription = null,
                        tint = if (wakeWordEnabled) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(24.dp)
                    )
                    Spacer(modifier = Modifier.width(16.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            "语音唤醒",
                            style = MaterialTheme.typography.bodyLarge
                        )
                        Text(
                            "说\"小爱小爱\"即可唤醒",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Switch(
                        checked = wakeWordEnabled,
                        onCheckedChange = onToggleWakeWord
                    )
                }
            }

            // Battery optimization warning
            if (showBatteryWarning) {
                item(key = "battery_warning") {
                    Surface(
                        onClick = {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                    data = android.net.Uri.parse("package:${context.packageName}")
                                }
                                context.startActivity(intent)
                            }
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                        color = MaterialTheme.colorScheme.errorContainer,
                        shape = MaterialTheme.shapes.medium
                    ) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            Icon(
                                Icons.Filled.BatteryAlert,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onErrorContainer,
                                modifier = Modifier.size(20.dp)
                            )
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    "关闭电池优化，确保后台唤醒",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onErrorContainer,
                                    fontWeight = FontWeight.Medium
                                )
                                Text(
                                    "系统可能会在后台停止语音唤醒服务,点击此处前往设置关闭电池优化。",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onErrorContainer.copy(alpha = 0.7f)
                                )
                            }
                            Icon(
                                Icons.Filled.ChevronRight,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onErrorContainer.copy(alpha = 0.5f),
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    }
                }
            }

            // Section: 关于
            item(key = "header_about") {
                SectionHeader("关于")
            }
            item(key = "version") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        Icons.Filled.Info,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(24.dp)
                    )
                    Spacer(modifier = Modifier.width(16.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            "版本",
                            style = MaterialTheme.typography.bodyLarge
                        )
                        Text(
                            appVersion,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(
        text = title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 24.dp, bottom = 8.dp)
    )
}

@Composable
private fun SettingsRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    onClick: () -> Unit
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 2.dp),
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClick = onClick)
                .padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(24.dp)
            )
            Spacer(modifier = Modifier.width(16.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    title,
                    style = MaterialTheme.typography.bodyLarge
                )
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Icon(
                Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                modifier = Modifier.size(20.dp)
            )
        }
    }
}
