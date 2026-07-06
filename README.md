# Mobile Robot — 纯手机版机器人伴侣

一部 Android 12 手机 = 机器人的眼睛、耳朵、嘴巴和脸。

**不需要任何外部硬件。** 前置摄像头看人脸，麦克风听语音，TTS 说话，屏幕显示一张会跟着你动的机器人脸。

## 功能

- 👀 **眼睛跟随** — 检测人脸后，屏幕上的眼睛会跟着你移动
- 😊 **表情系统** — 7 种情绪：开心/好奇/惊讶/害羞/困倦/难过/中性
- 🗣️ **语音对话** — 点屏幕说话，机器人用语音+表情回应
- 😉 **眨眼** — 随机眨眼，自然生动
- 🧠 **规则引擎** — 关键词匹配对话（可替换为 GPT/Claude API）

## 快速启动

### 1. 用 Android Studio 打开

```
File → Open → 选择 android/ 目录
```

### 2. 同步 Gradle

等待依赖下载完成（CameraX, ML Kit, Compose）。

### 3. 在手机上运行

- USB 连接手机，开启 USB 调试
- 点击 Run
- 首次启动需授权**相机**和**麦克风**权限

### 4. 互动

- 把脸对着手机 → 机器人眼睛看过来
- 点击屏幕 → 说话 → 机器人回应
- 走远 → 机器人说"你去哪了？"

## 项目结构

```
mobile_robot/
├── README.md
├── docs/
│   ├── architecture.md       # 系统架构
│   ├── hardware.md           # 硬件选型（将来买底盘时参考）
│   └── android_app.md        # App 技术方案
├── android/                   # Android App ★ 核心代码
│   ├── build.gradle.kts
│   ├── settings.gradle.kts
│   └── app/src/main/kotlin/com/mobilerobot/app/
│       ├── MainActivity.kt           # 入口，模块编排
│       ├── RobotApplication.kt       # Application
│       ├── camera/FaceDetector.kt    # CameraX + ML Kit
│       ├── voice/SpeechToText.kt     # 语音输入
│       ├── voice/RobotTTS.kt         # 语音输出
│       ├── ui/RobotFaceScreen.kt     # 脸部动画 UI
│       ├── robot/BehaviorEngine.kt   # 对话引擎
│       └── robot/RobotState.kt       # 状态模型
├── firmware/                  # ESP32 固件（将来买底盘后用）
└── models/                    # 预训练模型
```

## 下一步路线

| 阶段 | 内容 | 状态 |
|------|------|------|
| 0 | 纯手机：眼睛+语音+表情 | ✅ 当前 |
| 1 | 接大模型 API：智能对话 | 📋 替换 BehaviorEngine |
| 2 | 人脸识别：记住不同的人 | 📋 升级 ML Kit |
| 3 | 长期记忆：SQLite 存历史 | 📋 |
| 4 | 买底盘+ESP32：物理移动 | 📋 见 docs/hardware.md |
| 5 | SLAM 导航：自主巡航 | 📋 |
