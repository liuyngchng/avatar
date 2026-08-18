# 系统架构 — 数字人 Avatar

## 整体架构

```
┌──────────────────────────────────────────────────────────────┐
│                    iPhone / Android                           │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐   │
│  │ AudioRecorder│  │  AudioPlayer │  │  WakeWordEngine  │   │
│  │ 16kHz Mono   │  │ PCM Float    │  │  16kHz Mono      │   │
│  │ Float32 PCM  │  │ 16-22kHz     │  │  Zipformer KWS   │   │
│  └──────┬───────┘  └──────┬───────┘  └───────┬──────────┘   │
│         │                 │                   │              │
│   SherpaAsrEngine   SherpaTtsEngine    WakeWordManager       │
│   (SenseVoiceSmall) (Matcha-TTS)      (状态管理+防抖)        │
│         │                 │                   │              │
│         └─────────────────┼───────────────────┘              │
│                           │                                  │
│                   ┌───────┴──────────┐                       │
│                   │  RobotViewModel  │                       │
│                   │  状态机 + 编排    │                       │
│                   └───────┬──────────┘                       │
│                           │                                  │
│              ┌────────────┼────────────┐                     │
│              │            │            │                     │
│     BehaviorEngine   ChatSession   FaceDetector              │
│     (规则对话)       (LLM 对话)    (on-demand only)           │
│              │            │                                  │
│              └────────────┘                                  │
│                           │                                  │
│                   ┌───────┴──────────┐                       │
│                   │  RobotFaceView   │                       │
│                   │  (Canvas 绘制)    │                       │
│                   │  眼睛+嘴巴+表情   │                       │
│                   └──────────────────┘                       │
│                                                              │
│  底层: sherpa-onnx (C API / JNI)                             │
│  模型: SenseVoiceSmall + Matcha-TTS + Zipformer KWS          │
└──────────────────────────────────────────────────────────────┘
```

## 数据流

### 语音对话

```
麦克风
  → AudioRecorder → Float32 PCM 流
  → SherpaAsrEngine.acceptWaveform() → 缓冲 → 解码
  → 识别文本
  → ChatSession.sendStream(text) → LLM API → 流式返回
  → 回复文本
  → TextNormalizer → 分句
  → SherpaTtsEngine.synthesize() → Float32 PCM
  → AudioPlayer.play() → 扬声器
```

### 文字朗读（贴文字让她念）

```
用户输入文本
  → TextNormalizer.normalize() → 分句
  → SherpaTtsEngine.synthesize() → Float32 PCM
  → AudioPlayer.play() → 扬声器
```

### 表情动画

```
RobotMode + Emotion (状态机驱动)
  → RobotState.emotion → 脸部动画更新
  → 眨眼 (随机 2-5s 间隔)
  → 说话嘴型 (TTS 播放时)
  → 随机搞怪 (idle 时 5-15s 随机触发)
```

表情不再依赖摄像头——完全由状态机根据当前模式（idle/listening/thinking/speaking）和情绪驱动。

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

## 模块说明

| 模块 | 职责 | 技术 |
|------|------|------|
| **RobotFaceView** | 脸部渲染 (20fps) | Core Graphics / Compose Canvas |
| **RobotViewModel** | 主状态机，编排各模块 | Combine + Swift Concurrency / Coroutines |
| **SherpaAsrEngine** | 离线语音识别 | sherpa-onnx SenseVoiceSmall |
| **SherpaTtsEngine** | 离线语音合成 | sherpa-onnx Matcha-TTS + vocos |
| **WakeWordEngine** | 唤醒词检测 ("小火小火") | sherpa-onnx Zipformer KWS |
| **WakeWordManager** | 唤醒状态管理 + 自适应防抖 | Combine / StateFlow |
| **ChatSession** | 对话管理 | LLM HTTP streaming |
| **BehaviorEngine** | 规则对话 (无 LLM 时的后备) | 关键词匹配 |
| **FaceDetector** | 摄像头 + 人脸检测 (on-demand) | AVFoundation+Vision / CameraX+ML Kit |

## 性能优化

| 优化项 | 改动 |
|--------|------|
| 脸部渲染帧率 | 60fps → 20fps |
| CGGradient 对象 | 从每帧创建改为静态缓存 |
| 唤醒词线程优先级 | 1.0 → 0.75 |
| 分析队列 QoS | userInitiated → utility |
| VAD 噪声校准 | 启动时一次性校准环境噪声阈值 |
| 多轮对话防回声 | warm-up buffer 跳过 + 回声检测 + 连续静默自动退出 |
