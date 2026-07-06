package com.rd.siri.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.rd.siri.model.ModelManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class SlotState(
    val extracting: Boolean = false,
    val progress: Float = 0f,
    val error: String? = null
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModelSetupScreen(
    onReady: (() -> Unit)? = null,
    onBack: (() -> Unit)? = null
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    val asrReady = ModelManager.checkAsrReady(context)
    val ttsTarReady = ModelManager.checkTtsExtracted(context)
    val vocoderReady = ModelManager.checkVocoderReady(context)
    val kwsReady = ModelManager.checkKwsReady(context)

    var asrOk by remember { mutableStateOf(asrReady) }
    var ttsTarOk by remember { mutableStateOf(ttsTarReady) }
    var vocoderOk by remember { mutableStateOf(vocoderReady) }
    var kwsOk by remember { mutableStateOf(kwsReady) }

    var asrSlot by remember { mutableStateOf(SlotState()) }
    var ttsSlot by remember { mutableStateOf(SlotState()) }
    var vocoderSlot by remember { mutableStateOf(SlotState()) }
    var kwsSlot by remember { mutableStateOf(SlotState()) }

    val anyExtracting = asrSlot.extracting || ttsSlot.extracting || vocoderSlot.extracting || kwsSlot.extracting
    val ttsOk = ttsTarOk && vocoderOk
    val allReady = asrOk && ttsOk

    // ---- ASR picker ----
    val asrPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        uri?.let {
            scope.launch {
                asrSlot = SlotState(extracting = true)
                val result = withContext(Dispatchers.IO) {
                    ModelManager.extractTar(context, it, ModelManager.ASR_MODEL_DIR) { p ->
                        asrSlot = SlotState(extracting = true, progress = p)
                    }
                }
                result.fold(
                    onSuccess = { asrOk = ModelManager.checkAsrReady(context); asrSlot = SlotState() },
                    onFailure = { e -> asrSlot = SlotState(error = "解压失败: ${e.message}") }
                )
            }
        }
    }

    // ---- TTS tar picker ----
    val ttsPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        uri?.let {
            scope.launch {
                ttsSlot = SlotState(extracting = true)
                val result = withContext(Dispatchers.IO) {
                    ModelManager.extractTar(context, it, ModelManager.TTS_MODEL_DIR) { p ->
                        ttsSlot = SlotState(extracting = true, progress = p)
                    }
                }
                result.fold(
                    onSuccess = { ttsTarOk = ModelManager.checkTtsExtracted(context); ttsSlot = SlotState() },
                    onFailure = { e -> ttsSlot = SlotState(error = "解压失败: ${e.message}") }
                )
            }
        }
    }

    // ---- Vocoder picker ----
    val vocoderPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        uri?.let {
            scope.launch {
                vocoderSlot = SlotState(extracting = true)
                val result = withContext(Dispatchers.IO) {
                    ModelManager.copyVocoder(context, it) { p ->
                        vocoderSlot = SlotState(extracting = true, progress = p)
                    }
                }
                result.fold(
                    onSuccess = { vocoderOk = ModelManager.checkVocoderReady(context); vocoderSlot = SlotState() },
                    onFailure = { e -> vocoderSlot = SlotState(error = "复制失败: ${e.message}") }
                )
            }
        }
    }

    // ---- KWS picker ----
    val kwsPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        uri?.let {
            scope.launch {
                kwsSlot = SlotState(extracting = true)
                val result = withContext(Dispatchers.IO) {
                    ModelManager.extractTar(context, it, ModelManager.KWS_MODEL_DIR) { p ->
                        kwsSlot = SlotState(extracting = true, progress = p)
                    }
                }
                result.fold(
                    onSuccess = { kwsOk = ModelManager.checkKwsReady(context); kwsSlot = SlotState() },
                    onFailure = { e -> kwsSlot = SlotState(error = "解压失败: ${e.message}") }
                )
            }
        }
    }

    // ---- Download handlers ----
    fun downloadAsr() {
        scope.launch {
            asrSlot = SlotState(extracting = true)
            val result = withContext(Dispatchers.IO) {
                ModelManager.downloadAndExtractAsr(context) { p ->
                    asrSlot = SlotState(extracting = true, progress = p)
                }
            }
            result.fold(
                onSuccess = { asrOk = ModelManager.checkAsrReady(context); asrSlot = SlotState() },
                onFailure = { e -> asrSlot = SlotState(error = "下载失败: ${e.message}") }
            )
        }
    }

    fun downloadTts() {
        scope.launch {
            ttsSlot = SlotState(extracting = true)
            val result = withContext(Dispatchers.IO) {
                ModelManager.downloadAndExtractTts(context) { p ->
                    ttsSlot = SlotState(extracting = true, progress = p)
                }
            }
            result.fold(
                onSuccess = { ttsTarOk = ModelManager.checkTtsExtracted(context); ttsSlot = SlotState() },
                onFailure = { e -> ttsSlot = SlotState(error = "下载失败: ${e.message}") }
            )
        }
    }

    fun downloadVocoder() {
        scope.launch {
            vocoderSlot = SlotState(extracting = true)
            val result = withContext(Dispatchers.IO) {
                ModelManager.downloadVocoder(context) { p ->
                    vocoderSlot = SlotState(extracting = true, progress = p)
                }
            }
            result.fold(
                onSuccess = { vocoderOk = ModelManager.checkVocoderReady(context); vocoderSlot = SlotState() },
                onFailure = { e -> vocoderSlot = SlotState(error = "下载失败: ${e.message}") }
            )
        }
    }

    fun downloadKws() {
        scope.launch {
            kwsSlot = SlotState(extracting = true)
            val result = withContext(Dispatchers.IO) {
                ModelManager.downloadAndExtractKws(context) { p ->
                    kwsSlot = SlotState(extracting = true, progress = p)
                }
            }
            result.fold(
                onSuccess = { kwsOk = ModelManager.checkKwsReady(context); kwsSlot = SlotState() },
                onFailure = { e -> kwsSlot = SlotState(error = "下载失败: ${e.message}") }
            )
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("模型设置") },
                navigationIcon = {
                    if (onBack != null) {
                        IconButton(onClick = onBack) {
                            Icon(Icons.Filled.ArrowBack, contentDescription = "返回")
                        }
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
            verticalArrangement = Arrangement.spacedBy(20.dp)
        ) {
            Text(
                "首次使用需下载/上传模型文件",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            // Native lib status
            Card(modifier = Modifier.fillMaxWidth()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        Icons.Filled.CheckCircle,
                        contentDescription = null,
                        tint = Color(0xFF4CAF50),
                        modifier = Modifier.size(24.dp)
                    )
                    Spacer(modifier = Modifier.width(12.dp))
                    Column {
                        Text("sherpa-onnx 引擎", style = MaterialTheme.typography.titleSmall)
                        Text("已内置于 APK", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }

            // ASR model slot
            ModelSlotCard(
                label = "ASR 模型",
                isReady = asrOk,
                slot = asrSlot,
                onSelect = { asrPicker.launch(arrayOf("application/x-tar", "application/octet-stream")) },
                onDownload = { downloadAsr() }
            )

            // TTS model slot
            ModelSlotCard(
                label = "TTS 模型",
                isReady = ttsTarOk,
                slot = ttsSlot,
                onSelect = { ttsPicker.launch(arrayOf("application/x-tar", "application/octet-stream")) },
                onDownload = { downloadTts() }
            )

            // Vocoder slot
            ModelSlotCard(
                label = "Vocoder",
                isReady = vocoderOk,
                slot = vocoderSlot,
                onSelect = { vocoderPicker.launch(arrayOf("application/octet-stream", "*/*")) },
                onDownload = { downloadVocoder() }
            )

            // Section: 可选 — KWS 唤醒词模型
            Text(
                "可选：语音唤醒",
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(top = 8.dp)
            )
            Text(
                "启用\"小爱小爱\"语音唤醒所需的模型（~13MB）",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            ModelSlotCard(
                label = "KWS 唤醒词模型",
                isReady = kwsOk,
                slot = kwsSlot,
                onSelect = { kwsPicker.launch(arrayOf("application/x-tar", "application/octet-stream")) },
                onDownload = { downloadKws() }
            )

            // Start button (only in first-run wizard mode)
            if (onReady != null) {
                Spacer(modifier = Modifier.weight(1f))

                Button(
                    onClick = onReady,
                    modifier = Modifier.fillMaxWidth(),
                    enabled = allReady && !anyExtracting,
                    shape = RoundedCornerShape(10.dp),
                    contentPadding = PaddingValues(vertical = 12.dp)
                ) {
                    Text("下一步", style = MaterialTheme.typography.titleMedium)
                }
            }
        }
    }
}

@Composable
private fun ModelSlotCard(
    label: String,
    isReady: Boolean,
    slot: SlotState,
    onSelect: () -> Unit,
    onDownload: (() -> Unit)? = null
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    if (isReady) Icons.Filled.CheckCircle else Icons.Filled.Warning,
                    contentDescription = null,
                    tint = if (isReady) Color(0xFF4CAF50) else Color(0xFFFF9800),
                    modifier = Modifier.size(24.dp)
                )
                Spacer(modifier = Modifier.width(12.dp))
                Text(label, style = MaterialTheme.typography.titleSmall)
            }

            if (slot.extracting) {
                Spacer(modifier = Modifier.height(12.dp))
                Text(
                    "处理中 ${(slot.progress * 100).toInt()}%",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.primary
                )
                Spacer(modifier = Modifier.height(4.dp))
                if (slot.progress <= 0f) {
                    LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                } else {
                    LinearProgressIndicator(
                        progress = slot.progress,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            } else if (!isReady) {
                Spacer(modifier = Modifier.height(12.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    if (onDownload != null) {
                        Button(
                            onClick = onDownload,
                            modifier = Modifier.weight(1f),
                            shape = RoundedCornerShape(10.dp),
                            contentPadding = PaddingValues(vertical = 8.dp)
                        ) {
                            Text("下载")
                        }
                    }
                    OutlinedButton(
                        onClick = onSelect,
                        modifier = Modifier.weight(1f),
                        shape = RoundedCornerShape(10.dp),
                        contentPadding = PaddingValues(vertical = 8.dp)
                    ) {
                        Text("上传")
                    }
                }
            }

            // Per-slot error
            slot.error?.let {
                Spacer(modifier = Modifier.height(8.dp))
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error
                )
            }
        }
    }
}
