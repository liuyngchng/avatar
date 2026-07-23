# Avatar — 手机里的数字人

一个跑在 iPhone / Android 手机上的数字人。她能听懂你说的话、用自然的声音回答你，有丰富的表情动画。你也可以给她一段文字，让她念出来。

**不需要任何外部硬件。** 只有你的手机，和一个住在屏幕里的她。

## 她能做什么

- 🗣️ **语音对话** — 点屏幕说话，她听懂后回答你（ASR → LLM → TTS）
- 🔄 **多轮对话** — 唤醒后持续对话，直到你停下来（最多连续沉默 3 轮后自动结束）
- 📝 **文字朗读** — 贴一段文字给她，她用自然的声音念出来
- 🎤 **唤醒词** — 喊"小火小火"，她应一声"哎，我在呢"，然后听你说话
- 🎨 **丰富表情** — 8 种情绪（中性/开心/好奇/惊讶/害羞/困倦/难过/搞怪）+ 眨眼 + 说话时嘴巴张合，由状态机驱动
- 🤪 **随机搞怪** — 空闲时偶尔做鬼脸、说俏皮话
- 🌐 **多 LLM 支持** — 内置阿里百炼、DeepSeek、硅基流动预设，也支持自定义 OpenAI 兼容 API

## 平台支持

| | iOS | Android |
|---|---|---|
| **UI** | SwiftUI + UIKit (Core Graphics) | Jetpack Compose (Canvas) |
| **最低系统** | iOS 14.0 | Android 12 (API 31) |
| **语音识别** | sherpa-onnx SenseVoiceSmall (离线) | sherpa-onnx SenseVoiceSmall (离线) |
| **语音合成** | sherpa-onnx Matcha-TTS + vocos (离线) | sherpa-onnx Matcha-TTS + vocos (离线) |
| **唤醒词** | sherpa-onnx Zipformer KWS (离线) | sherpa-onnx Zipformer KWS + 前台服务 |
| **对话** | LLM API（可配置） | LLM API（可配置） |

两个平台功能完全对齐，共享相同的模型文件。

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

### 需要的模型

| 模型 | 用途 | 大小 |
|------|------|------|
| SenseVoiceSmall (int8) | 语音识别 (ASR) | ~158MB |
| Matcha-TTS + vocos | 语音合成 (TTS) | ~116MB |
| Zipformer KWS | 唤醒词 | ~13MB |

App 内置模型管理界面，支持从手机上传/解压 `.tar` / `.tar.bz2` 文件。

## 开始互动

- 点击屏幕 — 说话 — 她回答
- 或喊"**小火小火**"唤醒她，进入多轮对话模式
- 长按屏幕 → 进入设置（配置 LLM、管理模型、文字朗读）

## 技术栈

| 层 | iOS | Android |
|----|-----|---------|
| **UI** | SwiftUI + UIKit (Core Graphics 绘制脸部) | Jetpack Compose (Canvas 绘制脸部) |
| **语音识别** | sherpa-onnx SenseVoiceSmall (离线) | sherpa-onnx SenseVoiceSmall (离线 JNI) |
| **语音合成** | sherpa-onnx Matcha-TTS + vocos (离线) | sherpa-onnx Matcha-TTS + vocos (离线 JNI) |
| **唤醒词** | sherpa-onnx Zipformer KWS (离线) | sherpa-onnx Zipformer KWS + Foreground Service |
| **对话** | LLM API（兼容 OpenAI 接口） | LLM API（兼容 OpenAI 接口） |
| **状态管理** | Combine + Swift Concurrency | Kotlin Coroutines + StateFlow |
| **最低系统** | iOS 14.0 | Android 12 (API 31) |

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

App 支持两层对话：

| 引擎 | 说明 |
|------|------|
| **LLM 对话** | 配置 API endpoint + key 后，接入大模型对话。内置预设：阿里百炼(Qwen)、DeepSeek、硅基流动，也可配任意 OpenAI 兼容 API |
| **规则引擎** | 不配置 LLM 时，使用内置关键词匹配 + 俏皮话库作为后备，完全离线可用 |

## 给开发者

### 纯离线模式

如果你只让她念文字（不上传 LLM API key），那她**完全离线**：模型在本地，ASR 在本地，TTS 在本地，唤醒词在本地。不需要任何网络连接。

### 对话模式

配置 LLM API 后，语音对话功能启用。API key 通过 Keychain (iOS) / EncryptedSharedPreferences (Android) 安全存储。

### 模型兼容

iOS 和 Android 使用完全相同的模型文件——只需下载一次，两个平台通用。

### 代码风格

iOS 和 Android 代码结构完全镜像，文件名和模块划分一致，方便跨平台对照维护。



# 知识库 JSON 格式

## 样例文件

以下是一个完整的燃气知识库 JSON 样例，可直接用于导入测试。

```json
{
  "version": 1,
  "companyName": "昆昆燃气",
  "chunks": [
    {
      "id": "1",
      "text": "昆明市官渡区营业厅地址：云南省昆明市官渡区春城路109号，营业时间：周一至周五 8:30-17:30，周六 9:00-16:00，周日休息。联系电话：0871-63123456。",
      "keywords": ["营业厅", "官渡区", "地址", "昆明", "联系电话", "营业时间"],
      "embedding": []
    },
    {
      "id": "2",
      "text": "昆明市西山区营业厅地址：云南省昆明市西山区前兴路288号，营业时间：周一至周五 9:00-17:00，周六日休息。联系电话：0871-64123456。",
      "keywords": ["营业厅", "西山区", "地址", "昆明", "联系电话", "营业时间"],
      "embedding": []
    },
    {
      "id": "3",
      "text": "昆明市五华区营业厅地址：云南省昆明市五华区人民中路168号，营业时间：周一至周日 9:00-17:30。联系电话：0871-65123456。",
      "keywords": ["营业厅", "五华区", "地址", "昆明", "联系电话", "营业时间"],
      "embedding": []
    },
    {
      "id": "4",
      "text": "昆明市盘龙区营业厅地址：云南省昆明市盘龙区北京路520号，营业时间：周一至周五 8:30-17:00。联系电话：0871-66123456。",
      "keywords": ["营业厅", "盘龙区", "地址", "昆明", "联系电话", "营业时间"],
      "embedding": []
    },
    {
      "id": "5",
      "text": "昆明市呈贡区营业厅地址：云南省昆明市呈贡区彩云南路1666号，营业时间：周一至周五 9:00-17:00。联系电话：0871-67123456。",
      "keywords": ["营业厅", "呈贡区", "地址", "昆明", "联系电话", "营业时间"],
      "embedding": []
    },
    {
      "id": "6",
      "text": "居民用气价格：第一档（年用气量0-360立方米）2.98元/立方米；第二档（年用气量361-540立方米）3.58元/立方米；第三档（年用气量541立方米以上）4.47元/立方米。价格依据昆发改价格〔2023〕15号文件执行。",
      "keywords": ["气价", "价格", "居民", "阶梯", "收费标准", "燃气费"],
      "embedding": []
    },
    {
      "id": "7",
      "text": "非居民用气价格：商业用气3.80元/立方米，工业用气3.20元/立方米（具体以合同约定为准）。",
      "keywords": ["气价", "价格", "商业", "工业", "非居民"],
      "embedding": []
    },
    {
      "id": "8",
      "text": "如何查看燃气余额：1、物联网表：短按燃气表上的显示按钮，屏幕会显示剩余金额，再次点击可查看累积用气量和气价。也可进入「昆仑慧享+」服务号，绑定用户号后查看余额。2、插卡燃气表：将IC卡插入燃气表插槽，屏幕会显示剩余气量。",
      "keywords": ["余额", "查询", "燃气表", "物联网", "IC卡", "插卡", "查看"],
      "embedding": []
    },
    {
      "id": "9",
      "text": "燃气缴费方式：1、「昆仑慧享+」微信公众号在线缴费；2、支付宝/微信生活缴费；3、各营业厅柜台现金或刷卡缴费；4、银行代扣（需先到营业厅签约）。缴费后一般24小时内到账。",
      "keywords": ["缴费", "支付", "充值", "付款", "交费", "微信", "支付宝", "银行"],
      "embedding": []
    },
    {
      "id": "10",
      "text": "燃气报修流程：发现燃气泄漏请立即关闭表前阀门，打开门窗通风，切勿开关电器或使用明火，到室外安全区域后拨打24小时抢修电话：0871-63123119。日常燃气故障（如打不着火、火小）可拨打客服热线：0871-63123456或通过「昆仑慧享+」服务号报修。",
      "keywords": ["报修", "泄漏", "抢修", "故障", "安全", "电话", "打不着火", "火小"],
      "embedding": []
    },
    {
      "id": "11",
      "text": "新装燃气办理流程：1、携带身份证、房产证（或购房合同）到就近营业厅申请；2、预约上门勘察设计；3、缴纳安装费用；4、施工安装；5、验收通气。从申请到通气一般需要7-15个工作日。",
      "keywords": ["新装", "开户", "安装", "办理", "流程", "申请", "通气"],
      "embedding": []
    },
    {
      "id": "12",
      "text": "过户/销户办理：携带双方身份证、房产证、燃气表照片（显示当前读数）到营业厅办理。结清欠费后即可办理过户。销户需额外填写销户申请表，由工作人员上门拆表封堵。",
      "keywords": ["过户", "销户", "更名", "转让", "办理", "流程"],
      "embedding": []
    },
    {
      "id": "13",
      "text": "燃气表类型说明：目前使用的燃气表主要有两种：1、物联网表（NB-IoT）：支持远程抄表和手机缴费，无需插卡；2、IC卡表（插卡表）：需要持IC卡到营业厅或自助终端充值后，回家插卡使用。老旧小区部分仍为IC卡表，新装用户均安装物联网表。",
      "keywords": ["燃气表", "物联网表", "IC卡表", "插卡", "类型", "区别"],
      "embedding": []
    },
    {
      "id": "14",
      "text": "客服热线：0871-63123456，服务时间：周一至周日 8:00-20:00。24小时燃气抢修电话：0871-63123119。投诉建议请拨打：0871-63123888。",
      "keywords": ["客服", "电话", "热线", "抢修", "投诉", "联系方式"],
      "embedding": []
    }
  ]
}
```

## 字段说明

| 字段                 | 类型     | 必填 | 说明                                                   |
| -------------------- | -------- | ---- | ------------------------------------------------------ |
| `version`            | int      | ✅    | 知识库版本号，当前为 `1`                               |
| `companyName`        | string   | 否   | 燃气公司名称                                           |
| `chunks`             | array    | ✅    | 知识条目数组                                           |
| `chunks[].id`        | string   | ✅    | 唯一标识符                                             |
| `chunks[].text`      | string   | ✅    | 知识内容文本                                           |
| `chunks[].keywords`  | string[] | 否   | 关键词列表，用于提升关键词检索精度                     |
| `chunks[].embedding` | float[]  | 否   | 预计算的文本向量（PC端向量化后填入），**长度必须一致** |

## PC端向量化说明

`embedding` 字段为可选。若提供向量数据，App 将启用**混合检索模式**（关键词粗排 + 向量精排），显著提升召回率。

### 推荐 Embedding 模型

| 平台                | 模型                     | 向量维度 |
| ------------------- | ------------------------ | -------- |
| 阿里百炼            | `text-embedding-v3`      | 1024     |
| OpenAI              | `text-embedding-3-small` | 1536     |
| 通用（OpenAI 兼容） | 按实际模型填写           | -        |

### 向量化流程（PC 端）

1. 将公司文档分块（每块建议 100-300 字）
2. 调用 Embedding API 将每块文本转为向量
3. 将向量填入对应 chunk 的 `embedding` 数组
4. 导出为 JSON，通过文件 App 或隔空投送导入手机

### 注意事项

- 所有 chunk 的 `embedding` **长度必须相同**（同一模型生成）
- 混合检索时，App 会使用 LLM 配置中的 Embedding 模型对用户问题做向量化，与知识库向量计算余弦相似度
- 如不提供 `embedding`，App 自动降级为纯关键词检索模式
