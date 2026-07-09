# 系统架构 — 数字人 Avatar

## 整体架构

```
┌──────────────────────────────────────────────────────────────┐
│                       iPhone (iOS 14+)                        │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐   │
│  │  AVCapture   │  │ AudioRecorder│  │  AudioPlayer     │   │
│  │  + Vision    │  │ 16kHz Mono   │  │ PCM Float 16kHz  │   │
│  │  人脸+表情    │  │ Float32 PCM  │  │                  │   │
│  └──────┬───────┘  └──────┬───────┘  └───────┬──────────┘   │
│         │                 │                   │              │
│   FaceDetector     SherpaAsrEngine     SherpaTtsEngine       │
│   (Vision)         (SenseVoiceSmall)   (Matcha-TTS)          │
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
│     BehaviorEngine   ChatSession   WakeWordEngine            │
│     (规则对话)       (LLM 对话)    (Zipformer KWS)            │
│              │            │                                  │
│              └────────────┘                                  │
│                           │                                  │
│                   ┌───────┴──────────┐                       │
│                   │  RobotFaceView   │                       │
│                   │  Core Graphics   │                       │
│                   │  眼睛+嘴巴+表情   │                       │
│                   └──────────────────┘                       │
│                                                              │
│  底层: sherpa-onnx C API (sherpa-onnx.xcframework)           │
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

### 表情模仿

```
前置摄像头
  → AVCaptureSession → CVPixelBuffer
  → VNDetectFaceLandmarksRequest
  → VNFaceLandmarks2D (68 个特征点)
  → 计算:
     - 嘴角弧度 → smileAmount
     - 眉毛位置 → eyebrowRaise
     - 嘴巴开合 → mouthOpen
     - 眼睛开合 → leftEyeOpen / rightEyeOpen
  → FaceDetectionResult.inferredEmotion() → 情绪
  → RobotState.emotion → 脸部动画更新
```

## 状态机

```
         face detected
  IDLE ─────────────────→ WATCHING (表情模仿)
    ↑                        │
    │ face lost > 10s        │ tap / wake word
    │                        ↓
    │                    LISTENING
    │                        │
    │                        │ VAD silence / manual stop
    │                        ↓
    │                    THINKING
    │                        │
    │                        │ LLM response ready
    │                        ↓
    └─────────────────── SPEAKING
```

## 模块说明

| 模块 | 职责 | 技术 |
|------|------|------|
| **FaceDetector** | 摄像头 + 人脸检测 + 表情分析 | AVFoundation + Vision |
| **RobotFaceView** | 脸部渲染 (60fps → 20fps 优化后) | Core Graphics + CADisplayLink |
| **RobotViewModel** | 主状态机，编排各模块 | Combine + Swift Concurrency |
| **SherpaAsrEngine** | 离线语音识别 | sherpa-onnx SenseVoiceSmall |
| **SherpaTtsEngine** | 离线语音合成 | sherpa-onnx Matcha-TTS + vocos |
| **WakeWordEngine** | 唤醒词检测 ("小爱小爱") | sherpa-onnx Zipformer KWS |
| **ChatSession** | 对话管理 | Combine + LLM HTTP streaming |
| **BehaviorEngine** | 规则对话 (无 LLM 时的后备) | 关键词匹配 |

## 降热优化（2024.07）

手机发热问题已做专项优化：

| 优化项 | 改动 |
|--------|------|
| 脸部渲染帧率 | 60fps → 20fps (idle 模式 10fps) |
| Vision 人脸检测 | 每 4 帧跑一次 (~7.5Hz) |
| CGGradient 对象 | 从每帧创建改为静态缓存 |
| 唤醒词线程优先级 | 1.0 → 0.75 |
| 分析队列 QoS | userInitiated → utility |
