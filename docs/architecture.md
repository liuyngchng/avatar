# 系统架构 v0.2 — 离线语音栈

## 整体架构

```
┌──────────────────────────────────────────────────────────┐
│                   Android 12 手机                         │
│                                                          │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────────┐  │
│  │ CameraX     │  │ AudioRecorder│  │  AudioPlayer    │  │
│  │ + ML Kit    │  │ 16kHz Mono   │  │ AudioTrack PCM  │  │
│  │ 人脸检测    │  │ FloatArray   │  │ 22050Hz Mono    │  │
│  └──────┬──────┘  └──────┬───────┘  └────────┬────────┘  │
│         │                │                   │            │
│  FaceDetector     SherpaAsrEngine      SherpaTtsEngine    │
│  (com.mobilerobot) (com.rd.siri.asr)  (com.rd.siri.tts)  │
│         │                │                   │            │
│         └────────────────┼───────────────────┘            │
│                          │                                │
│                  ┌───────┴────────┐                       │
│                  │ BehaviorEngine │                       │
│                  │  FSM + 对话    │                       │
│                  └───────┬────────┘                       │
│                          │                                │
│                  ┌───────┴────────┐                       │
│                  │ RobotFace UI   │                       │
│                  │ 眼睛+嘴巴+表情  │                       │
│                  └────────────────┘                       │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │ VoiceService (后台)                                │  │
│  │ WakeWordEngine → "小机小机" → 唤醒                 │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  底层: sherpa-onnx JNI (libsherpa-onnx-c-api.so)         │
│  模型: SenseVoiceSmall + Matcha-TTS + Zipformer KWS      │
└──────────────────────────────────────────────────────────┘
```

## 模块来源

| 模块 | 来源 | 包名 |
|------|------|------|
| **FaceDetector** | mobile_robot 原创 | `com.mobilerobot.app.camera` |
| **RobotFaceScreen** | mobile_robot 原创 | `com.mobilerobot.app.ui` |
| **BehaviorEngine** | mobile_robot 原创 | `com.mobilerobot.app.robot` |
| **SherpaAsrEngine** | 从 siri 搬 | `com.rd.siri.asr` |
| **SherpaTtsEngine** | 从 siri 搬 | `com.rd.siri.tts` |
| **AudioRecorder** | 从 siri 搬 | `com.rd.siri.audio` |
| **AudioPlayer** | 从 siri 搬 | `com.rd.siri.audio` |
| **WakeWordEngine** | 从 siri 搬 | `com.rd.siri.audio` |
| **VoiceService** | 从 siri 搬 | `com.rd.siri.audio` |
| **ModelManager** | 从 siri 搬 | `com.rd.siri.model` |
| **sherpa_onnx_jni.c** | 从 siri 搬 | `cpp/` |
| **libsherpa-onnx-c-api.so** | 从 siri 搬 | `jniLibs/` |

## 语音数据流 (离线)

```
麦克风
  → AudioRecorder.startRecording()  Flow<FloatArray>
  → SherpaAsrEngine.acceptWaveform() 缓冲采样
  → SherpaAsrEngine.inputFinished()  解码
  → 识别文本
  → BehaviorEngine.respond(text)     对话
  → 回复文本
  → SherpaTtsEngine.synthesize()     FloatArray PCM
  → AudioPlayer.play(audio)         播放
```

## 模型文件

| 模型 | 文件 | 大小 | 用途 |
|------|------|------|------|
| SenseVoiceSmall int8 | `models/asr/model.int8.onnx` + `tokens.txt` | ~158MB | ASR 离线识别 |
| Matcha-TTS zh-baker | `models/tts/model.onnx` + `tokens.txt` + `lexicon.txt` | ~72MB | TTS 语音合成 |
| vocos | `models/tts/vocos.onnx` | ~51MB | 声码器 |
| Zipformer 3.3M | `models/kws/encoder.onnx` + `decoder.onnx` + `joiner.onnx` + `tokens.txt` | ~13MB | 唤醒词 |

用 `./download-models.sh` 下载 → 在 App 内上传/解压。

## VS 旧版 (v0.1)

| | v0.1 (已删除) | v0.2 (现在) |
|---|---|---|
| ASR | RecognizerIntent (在线) | SenseVoiceSmall (离线) |
| TTS | Android 内置 (机械音) | Matcha-TTS (自然语音) |
| 唤醒词 | ❌ | "小机小机" |
| 网络 | 依赖 Google | 完全离线 |
| 中文 | 勉强 | 优秀 |
