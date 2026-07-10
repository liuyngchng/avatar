# Avatar — 手机里的数字人

一个跑在 iPhone 上的数字人。她会看着你、模仿你的表情、听懂你说的话、用自然的声音回答你。你也可以给她一段文字，让她念出来。

**不需要任何外部硬件。** 只有你的手机，和一个住在屏幕里的她。

## 她能做什么

- 👀 **眼神跟随** — 前置摄像头检测人脸，眼睛会一直看着你
- 😊 **表情模仿** — 你笑她就笑，你惊讶她就惊讶，你眯眼她就犯困
- 🗣️ **语音对话** — 点屏幕说话，她听懂后回答你（ASR → LLM → TTS）
- 📝 **文字朗读** — 贴一段文字给她，她用自然的声音念出来
- 🎤 **唤醒词** — 喊"小爱小爱"，她应一声"哎，我在呢"，然后听你说话
- 🎨 **生动表情** — 7 种情绪 + 眨眼 + 说话时嘴巴张合

## 快速开始

### 1. 用 Xcode 打开

```
open ios/Avatar/Avatar.xcodeproj
```

### 2. 准备模型文件

App 内置模型管理界面，可以从手机上传/解压模型文件。需要的模型：

| 模型 | 用途 | 大小 |
|------|------|------|
| SenseVoiceSmall | 语音识别 (ASR) | ~158MB |
| VITS-aishell3 | 语音合成 (TTS) | ~116MB |
| Zipformer KWS | 唤醒词 | ~13MB |

### 3. 在手机上运行

- USB 连接 iPhone
- Xcode 中选择你的设备，点 Run
- 首次启动授权**相机**和**麦克风**

### 4. 开始互动

- 把脸对着手机 — 她会看着你，模仿你的表情
- 点击屏幕 — 说话 — 她回答
- 或喊"小爱小爱"唤醒她

## 技术栈

| 层 | 技术 |
|----|------|
| **UI** | SwiftUI + UIKit (Core Graphics 绘制脸部) |
| **人脸检测** | AVFoundation + Vision (`VNDetectFaceLandmarksRequest`) |
| **语音识别** | sherpa-onnx SenseVoiceSmall (离线) |
| **语音合成** | sherpa-onnx VITS (离线) |
| **唤醒词** | sherpa-onnx Zipformer KWS (离线) |
| **对话** | LLM API（可配置 OpenAI / Claude / 本地模型） |
| **最低系统** | iOS 14.0 |

## 项目结构

```
ios/Avatar/
├── Avatar.xcodeproj
├── Avatar/
│   ├── AvatarApp.swift               # App 入口
│   ├── ContentView.swift             # 根导航
│   ├── ViewModels/
│   │   ├── RobotViewModel.swift      # 核心编排：感知→决策→表达
│   │   └── ContentViewModel.swift    # 导航状态
│   ├── Views/
│   │   ├── RobotMainScreen.swift     # 主界面
│   │   ├── RobotFaceView.swift       # 脸部渲染 (UIKit)
│   │   ├── FaceParts.swift           # 脸部绘制 (眼/眉/嘴/耳/天线)
│   │   ├── SettingsScreen.swift      # 设置页
│   │   ├── ModelSetupScreen.swift    # 模型上传
│   │   └── ...
│   ├── Services/
│   │   ├── FaceDetector.swift        # Vision 人脸检测 + 表情分析
│   │   └── BehaviorEngine.swift      # 规则对话引擎 (无 LLM 时的后备)
│   ├── ASR/
│   │   └── SherpaAsrEngine.swift     # sherpa-onnx 语音识别
│   ├── TTS/
│   │   ├── SherpaTtsEngine.swift     # sherpa-onnx 语音合成
│   │   └── TextNormalizer.swift      # 文本预处理
│   ├── Audio/
│   │   ├── AudioRecorder.swift       # 录音
│   │   ├── AudioPlayer.swift         # 播放
│   │   ├── WakeWordEngine.swift      # 唤醒词检测
│   │   └── WakeWordManager.swift     # 唤醒状态管理
│   ├── Chat/
│   │   ├── ChatSession.swift         # 对话管理
│   │   └── LlmClient.swift           # LLM API 客户端
│   ├── Models/                       # 数据模型
│   └── Config/                       # 配置管理
├── Frameworks/
│   ├── sherpa-onnx.xcframework
│   └── onnxruntime.xcframework
└── generate_icon.py
```

## 给开发者

全部离线运行，不依赖云端。LLM 对话需要网络，但可以配置你自己的 API endpoint。

如果你只想让她念文字（不上传 LLM），那她完全离线：模型在本地，ASR 在本地，TTS 在本地。



kokoro 模型下载地址： https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_1.tar.bz2

int8 量化版：https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_1.tar.bz2



- **SID 49**: `zm_yunjian`
- **SID 50**: `zm_yunxi`
- **SID 51**: `zm_yunxia`
- **SID 52**: `zm_yunyang`

This release contains pre-trained tts models.

Please refer to
https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/index.html
for more models.

Also, please see https://k2-fsa.github.io/sherpa/onnx/tts/all/ for usages.

Pre-built Android APKs are available at https://k2-fsa.github.io/sherpa/onnx/tts/apk.html

