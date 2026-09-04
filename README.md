# Avatar — 数字人

一个跑在 iPhone / Android 手机和大屏 PC 上的数字人。她能听懂你说的话、用自然的声音回答你，有丰富的表情动画。你也可以给她一段文字，让她念出来。

**不需要任何外部硬件。** 一部手机，或一台大屏 PC，和一个住在屏幕里的她。

## 她能做什么

- 🗣️ **语音对话** — 点屏幕说话，她听懂后回答你（ASR → LLM → TTS）
- 🔄 **多轮对话** — 唤醒后持续对话，直到你停下来（最多连续沉默 3 轮后自动结束）
- 📝 **文字朗读** — 贴一段文字给她，她用自然的声音念出来
- 🎤 **唤醒词** — 喊"小然小然"，她应一声"哎，我在呢"，然后听你说话
- 🎨 **丰富表情** — 8 种情绪（中性/开心/好奇/惊讶/害羞/困倦/难过/搞怪）+ 眨眼 + 说话时嘴巴张合，由状态机驱动（PC 端升级为 3D blendshape 真口型同步）
- 🤪 **随机搞怪** — 空闲时偶尔做鬼脸、说俏皮话
- 🖥️ **3D 数字人 (PC)** — 基于 three.js + three-vrm，真口型同步（拼音→viseme），支持 VRM blendshape 表情
- 🌐 **多 LLM 支持** — 内置阿里百炼、DeepSeek、硅基流动预设，也支持自定义 OpenAI 兼容 API

## 平台支持

| | iOS | Android | PC |
|---|---|---|---|
| **UI** | SwiftUI + UIKit (Core Graphics) | Jetpack Compose (Canvas) | Go + three.js + three-vrm (3D) |
| **最低系统** | iOS 14.0 | Android 12 (API 31) | Windows 10 1809+ / Ubuntu 24.04 |
| **语音识别** | sherpa-onnx SenseVoiceSmall (离线) | sherpa-onnx SenseVoiceSmall (离线) | sherpa-onnx SenseVoiceSmall (离线) |
| **语音合成** | sherpa-onnx Matcha-TTS + vocos (离线) | sherpa-onnx Matcha-TTS + vocos (离线) | sherpa-onnx Matcha-TTS + vocos (离线) |
| **唤醒词** | sherpa-onnx Zipformer KWS (离线) | sherpa-onnx Zipformer KWS + 前台服务 | sherpa-onnx Zipformer KWS (离线) |
| **对话** | LLM API（可配置） | LLM API（可配置） | LLM API（可配置） |

三个平台功能对齐，共享相同的离线模型文件。PC 端升级为 3D VRM 数字人，支持真口型同步（拼音→viseme）和表情 blendshape。

## 快速开始

### iOS

1. 用 Xcode 打开项目：
   ```
   open ios/Avatar/Avatar.xcodeproj
   ```

2. 下载模型文件（在项目根目录）：
   ```
   ./download-models.sh
   ```

3. 将 `.tar` 文件传到手机上，在 App 的模型管理界面依次上传

4. USB 连接 iPhone，Xcode 中选择设备，点 Run

5. 首次启动授权**麦克风**

### Android

1. 用 Android Studio 打开 `android/` 目录

2. 下载模型文件：
   ```
   ./download-models.sh
   ```

3. 将 `.tar` 文件传到手机上，在 App 的模型管理界面依次上传

4. 连接手机，点 Run

5. 首次启动授权**麦克风**

### PC

1. 进入 PC 目录：
   ```
   cd desktop/
   ```

2. 下载模型文件：
   ```
   cd scripts/ && ./download-models.sh && cd ..
   ```

3. 准备 VRM 3D 模型（用 VRoid Studio 免费制作，或下载 CC0 模型），放到 `web/models/avatar.vrm`

4. 配置 LLM：
   ```
   cp cfg.yml.template cfg.yml
   # 编辑 cfg.yml，填入 API key 和 model
   ```

5. 运行：
   ```
   make run
   ```
   或编译后运行：
   ```
   make build
   ./avatar-desktop
   ```

详细说明见 [desktop/README.md](desktop/README.md)。

### 需要的模型

| 模型 | 用途 |
|------|------|
| SenseVoice | 语音识别 (`ASR`) |
| Matcha-TTS + vocos | 语音合成 (`TTS`) |
| Zipformer KWS | 唤醒词 |

`App` 内置模型管理界面，支持从手机上传/解压 `.tar` / `.tar.bz2` 文件。

## 开始互动

- 点击屏幕 — 说话 — 她回答（PC 端支持鼠标点击）
- 或喊"**小冉小冉**"唤醒她，进入多轮对话模式
- 长按屏幕 → 进入设置（配置 LLM、管理模型、文字朗读）

## 技术栈

| 层 | iOS | Android | PC |
|----|-----|---------|-----|
| **UI** | SwiftUI + UIKit (Core Graphics 绘制脸部) | Jetpack Compose (Canvas 绘制脸部) | Go + three.js + three-vrm (WebGL 3D) |
| **语音识别** | sherpa-onnx SenseVoiceSmall (离线) | sherpa-onnx SenseVoice (离线 JNI) | sherpa-onnx SenseVoice(离线 `CGo`) |
| **语音合成** | sherpa-onnx Matcha-TTS + vocos (离线) | sherpa-onnx Matcha-TTS + vocos (离线 JNI) | sherpa-onnx Matcha-TTS + vocos (离线 `CGo`) |
| **唤醒词** | sherpa-onnx Zipformer KWS (离线) | sherpa-onnx Zipformer KWS + Foreground Service | sherpa-onnx Zipformer KWS (离线 `CGo`) |
| **对话** | `LLM` `API`（兼容 `OpenAI` 接口） | `LLM` `API`（兼容 `OpenAI` 接口） | `LLM` `API`（兼容 `OpenAI` 接口） |
| **状态管理** | Combine + Swift Concurrency | Kotlin Coroutines + StateFlow | Go Channel + State Machine |
| **最低系统** | iOS 14.0 | Android 12 (`API` 31) | Windows 10 1809+ / Ubuntu 24.04 |

## 项目结构

```
avatar/
├── ios/Avatar/                         # iOS App
│   ├── Avatar.xcodeproj
│   ├── Avatar/
│   │   ├── AvatarApp.swift             # App 入口
│   │   ├── AppDelegate.swift           # App 生命周期
│   │   ├── ContentView.swift           # 根导航
│   │   ├── ViewModels/
│   │   │   ├── RobotViewModel.swift    # 核心编排：感知→决策→表达
│   │   │   └── ContentViewModel.swift  # 导航状态
│   │   ├── Views/
│   │   │   ├── RobotMainScreen.swift   # 主界面
│   │   │   ├── RobotFaceView.swift     # 脸部渲染 (UIKit)
│   │   │   ├── FaceParts.swift         # 脸部绘制 (眼/眉/嘴/耳/天线)
│   │   │   ├── SettingsHubScreen.swift # 设置主页
│   │   │   ├── SettingsScreen.swift    # LLM 配置页
│   │   │   ├── ModelSetupScreen.swift  # 模型上传
│   │   │   ├── TextReaderView.swift    # 文字朗读
│   │   │   └── BlurView.swift          # UIKit 模糊效果桥接
│   │   ├── Services/
│   │   │   ├── FaceDetector.swift      # Vision 人脸检测 + 表情分析
│   │   │   └── BehaviorEngine.swift    # 规则对话引擎 (无 LLM 时的后备)
│   │   ├── ASR/
│   │   │   └── SherpaAsrEngine.swift   # sherpa-onnx 语音识别
│   │   ├── TTS/
│   │   │   ├── SherpaTtsEngine.swift   # sherpa-onnx 语音合成 (Matcha-TTS)
│   │   │   └── TextNormalizer.swift    # 文本预处理 + 分句
│   │   ├── Audio/
│   │   │   ├── AudioRecorder.swift     # 录音
│   │   │   ├── AudioPlayer.swift       # 播放
│   │   │   ├── AudioSessionManager.swift # 音频会话管理
│   │   │   ├── WakeWordEngine.swift    # 唤醒词检测
│   │   │   └── WakeWordManager.swift   # 唤醒状态管理 + 自适应防抖
│   │   ├── Chat/
│   │   │   ├── ChatSession.swift       # 对话管理
│   │   │   └── LlmClient.swift         # LLM API 客户端
│   │   ├── Config/
│   │   │   ├── ConfigRepository.swift  # 配置持久化
│   │   │   └── ConfigViewModel.swift   # 配置 ViewModel
│   │   ├── Helpers/
│   │   │   ├── ModelManager.swift      # 模型下载/导入/解压管理
│   │   │   ├── TarBz2Extractor.swift   # tar.bz2 解压
│   │   │   ├── KeychainHelper.swift    # API Key 安全存储
│   │   │   ├── DesignTokens.swift      # 设计令牌
│   │   │   └── Extensions.swift        # Swift 扩展
│   │   ├── Models/
│   │   │   ├── RobotState.swift        # 状态机 (RobotMode + Emotion)
│   │   │   ├── FaceDetectionResult.swift # 人脸检测结果
│   │   │   ├── ChatMessage.swift       # 对话消息模型
│   │   │   ├── LlmConfig.swift         # LLM 配置模型
│   │   │   └── LlmPreset.swift         # LLM 预设 (阿里百炼/DeepSeek/硅基流动)
│   │   └── Assets.xcassets/
│   └── Frameworks/
│       ├── sherpa-onnx.xcframework
│       └── onnxruntime.xcframework
│
├── android/                            # Android App
│   ├── app/src/main/java/com/rd/avatar/
│   │   ├── MainActivity.kt            # 主 Activity (状态机 + 录音 + TTS)
│   │   ├── RobotApplication.kt        # Application (加载 sherpa_onnx_jni)
│   │   ├── asr/SherpaAsrEngine.kt     # 语音识别引擎
│   │   ├── tts/SherpaTtsEngine.kt     # 语音合成引擎 (Matcha-TTS)
│   │   ├── tts/TextNormalizer.kt      # 文本预处理
│   │   ├── audio/
│   │   │   ├── AudioRecorder.kt       # 录音 + VAD
│   │   │   ├── AudioPlayer.kt         # 播放
│   │   │   ├── VoiceService.kt        # 唤醒词前台服务
│   │   │   ├── WakeWordEngine.kt      # 唤醒词检测
│   │   │   └── WakeWordManager.kt     # 唤醒状态管理
│   │   ├── camera/FaceDetector.kt     # CameraX + ML Kit 人脸检测
│   │   ├── chat/
│   │   │   ├── ChatSession.kt         # 对话管理
│   │   │   └── LlmClient.kt           # LLM API 客户端
│   │   ├── config/
│   │   │   ├── ConfigRepository.kt    # 加密配置存储
│   │   │   ├── ConfigViewModel.kt     # 配置 ViewModel
│   │   │   └── LlmConfig.kt           # LLM 配置模型
│   │   ├── model/
│   │   │   ├── ChatMessage.kt         # 对话消息
│   │   │   └── ModelManager.kt        # 模型文件管理
│   │   ├── robot/
│   │   │   ├── RobotState.kt          # 状态机
│   │   │   └── BehaviorEngine.kt      # 规则对话
│   │   └── ui/
│   │       ├── RobotFaceScreen.kt     # 脸部渲染 (Canvas)
│   │       ├── SettingsHubScreen.kt   # 设置主页
│   │       ├── SettingsScreen.kt      # LLM 配置页
│   │       ├── ModelSetupScreen.kt    # 模型管理
│   │       └── TextReaderScreen.kt    # 文字朗读
│   └── app/src/main/cpp/              # JNI 原生代码 (sherpa-onnx)
│
├── desktop/                                  # PC 大屏 3D 数字人
│   ├── main.go                           # 入口，启动窗口 + 大脑
│   ├── Makefile
│   ├── cfg.yml.template                  # LLM 配置模板
│   ├── cmd/avatar-ui/main.c              # GTK3 + WebKit2GTK 窗口宿主 (Linux)
│   ├── internal/
│   │   ├── brain/                        # 状态机 + 情绪 + 拼音→viseme 映射
│   │   ├── asr/                          # CGo 封装 sherpa-onnx ASR
│   │   ├── tts/                          # CGo 封装 sherpa-onnx TTS + 文本归一化
│   │   ├── kws/                          # CGo 封装 sherpa-onnx KWS 唤醒词
│   │   ├── llm/                          # LLM HTTP 流式客户端
│   │   ├── audio/                        # 音频 I/O (malgo)
│   │   └── renderer/                     # WebView2 (Win) / GTK+WebKit (Linux) 渲染器 + JS Bridge
│   ├── web/                              # 前端渲染 (three.js + three-vrm)
│   │   ├── index.html
│   │   ├── js/
│   │   └── models/                       # VRM 3D 模型
│   ├── models/                           # 离线模型（不提交 git）
│   │   ├── asr/
│   │   ├── tts/
│   │   └── kws/
│   └── scripts/
│       └── download-models.sh
│
├── firmware/esp32/                     # ESP32 硬件伴侣 (WIP)
├── docs/architecture.md                # 系统架构文档
├── download-models.sh                  # 模型下载脚本
└── scripts/                            # 工具脚本
```

## 状态机

```
              tap / wake word
    IDLE ─────────────────→ LISTENING
      ↑                        │
      │                        │ VAD silence / manual stop
      │                        ↓
      │                    THINKING
      │                        │
      │                        │ LLM response ready
      │                        ↓
      └──────────────────── SPEAKING
```

唤醒词触发的多轮对话：IDLE → (唤醒) → SPEAKING (打招呼) → LISTENING → THINKING → SPEAKING → LISTENING → … → 连续 3 轮无声 → IDLE

## 对话引擎

支持两层对话：

| 引擎 | 说明 |
|------|------|
| **LLM 对话** | 配置 API endpoint + key 后，接入大模型对话。内置预设：阿里百炼(Qwen)、DeepSeek、硅基流动，也可配任意 OpenAI 兼容 API |
| **规则引擎** | 不配置 LLM 时，使用内置关键词匹配 + 俏皮话库作为后备，完全离线可用 |

## 给开发者

### 纯离线模式

如果不配置 LLM API key，数字人**完全离线**运行：模型在本地，ASR 在本地，TTS 在本地，唤醒词在本地。移动端支持文字朗读（TTS 念文字），PC 端使用内置规则引擎作为对话后备。不需要任何网络连接。

### 对话模式

配置 LLM API 后，语音对话功能启用。API key 通过 Keychain (iOS) / EncryptedSharedPreferences (Android) / 本地 cfg.yml (PC) 安全存储。

### 模型兼容

iOS、Android 和 PC 使用完全相同的离线模型文件（SenseVoiceSmall / Matcha-TTS / Zipformer KWS）——只需下载一次，三个平台通用。注意 PC 端 TTS 用 Matcha-TTS 而非 VITS，需用 `desktop/scripts/download-models.sh` 下载。

### 代码风格

iOS 和 Android 代码结构完全镜像，文件名和模块划分一致，方便跨平台对照维护。PC 端用 Go 重写同一套状态机和链路，模块划分（brain / asr / tts / kws / llm / audio）一一对应。
