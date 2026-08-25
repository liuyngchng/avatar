# Avatar Desktop 用户手册

欢迎使用 Avatar Desktop！这是一款运行在 Linux 桌面上的 3D 数字人，可以与您进行语音对话。

## 目录

- [快速开始](#快速开始)
- [配置](#配置)
- [交互方式](#交互方式)
- [对话流程](#对话流程)
- [窗口操作](#窗口操作)
- [常见问题](#常见问题)

---

## 快速开始

### 1. 系统要求

- Ubuntu 24.04 **桌面版**（需要图形界面）
- 麦克风（用于语音输入）
- 扬声器（用于播放数字人语音）

### 2. 解压与安装依赖

```bash
# 解压
tar xzf avatar-desktop-*.tar.gz
cd avatar-desktop-*/

# 安装运行时依赖（如果缺失）
sudo apt update
sudo apt install -y libgtk-3-0 libwebkit2gtk-4.1-0 libasound2
```

### 3. 配置 LLM API

数字人需要连接到 LLM（大语言模型）才能进行对话。编辑 `cfg.yml`，填入您的 API 信息：

```yaml
llm:
  base_url: "https://api.deepseek.com"    # API 地址
  api_key: "sk-xxxxxxxx"                  # 您的 API Key
  model: "deepseek-v4-flash"              # 模型名称
  name: "小然"                             # 数字人名字
```

> **提示**：API 地址、Key 和模型也可以通过环境变量设置，优先级高于 `cfg.yml`：
>
> ```bash
> export AVATAR_LLM_BASE_URL="https://api.deepseek.com"
> export AVATAR_LLM_API_KEY="sk-xxxxxxxx"
> export AVATAR_LLM_MODEL="deepseek-v4-flash"
> ```

### 4. 启动

```bash
./avatar-desktop
```

启动后，数字人窗口会出现在屏幕右下角，等待您的唤醒。

---

## 配置

### cfg.yml 完整配置项

| 配置项 | 说明 | 默认值 |
|--------|------|--------|
| `llm.base_url` | LLM API 地址（OpenAI 兼容格式） | — |
| `llm.api_key` | API Key | — |
| `llm.model` | 模型名称 | — |
| `llm.name` | 数字人名字，影响唤醒词和系统提示词 | `小然` |
| `wake_word` | 自定义唤醒词，留空则自动生成 | 空（自动） |
| `enable_fbx` | 是否加载 FBX 动画（空闲时会随机播放动作） | `true` |

### 唤醒词

如果不配置 `wake_word`，程序会自动从 `llm.name` 生成。例如名字为"小然"时，唤醒词为"小然小然"（名称重复两遍）。

### 环境变量

以下环境变量可以覆盖 `cfg.yml` 中的配置：

| 环境变量 | 对应配置 |
|----------|----------|
| `AVATAR_LLM_BASE_URL` | `llm.base_url` |
| `AVATAR_LLM_API_KEY` | `llm.api_key` |
| `AVATAR_LLM_MODEL` | `llm.model` |

---

## 交互方式

### 发起对话

有两种方式可以开始与数字人对话：

| 方式 | 操作 |
|------|------|
| **语音唤醒** | 说出唤醒词（默认"小然小然"），数字人回应"哎，我在呢"后即可说话 |
| **点击/按键** | 点击数字人角色，或按**空格键** / **回车键**，数字人进入聆听状态 |

### 对话流程

1. **唤醒**：说"小然小然"或点击/按键 → 数字人回应"哎，我在呢"
2. **聆听**：数字人开始倾听，您可以直接说话
3. **思考**：识别到您的语音后，数字人进入思考状态，连接 LLM 生成回复
4. **说话**：数字人开始播放语音回复，同时有口型同步动画
5. **返回空闲**：说完后回到空闲状态，等待下一次唤醒

> 对话支持多轮上下文，数字人会记住最近 10 轮对话内容。

### 状态说明

| 状态 | 表现 |
|------|------|
| 空闲 | 数字人自然站立，偶尔有随机动作 |
| 聆听 | 数字人身体前倾，表示正在倾听 |
| 思考 | 数字人做出思考动作 |
| 说话 | 数字人说话，口型同步 |

---

## 窗口操作

### 移动窗口

| 操作 | 说明 |
|------|------|
| `Ctrl` + 鼠标拖拽 | 按住 Ctrl 键，用鼠标拖拽角色移动窗口 |
| `W` `A` `S` `D` 或方向键 | 用键盘移动窗口 |

### 旋转视角

| 操作 | 说明 |
|------|------|
| 鼠标拖拽（不按 Ctrl） | 在角色上拖拽鼠标，旋转观察视角 |

### 退出程序

按 `Ctrl + C`（在终端中），或直接关闭窗口。

---

## 常见问题

### Q: 数字人没有反应？

检查终端输出，确认：
- `cfg.yml` 中的 LLM API 配置是否正确（base_url、api_key、model）
- 麦克风是否正常工作

### Q: 说唤醒词没反应？

- 确保麦克风工作正常，没有被其他程序占用
- 尝试用鼠标点击或按空格键手动触发对话
- 如果 `name` 不是"小然"，唤醒词会自动变化，确认当前唤醒词

### Q: 数字人不说话？

- 确认 LLM API 配置正确，网络可以访问 API 地址
- 查看终端输出中的错误信息
- 如果未配置 LLM，数字人会使用默认回复"你好，我是企业数字人，请问有什么可以帮你的？"

### Q: 没有声音？

- 检查扬声器是否正常工作
- 确认系统音量没有静音

### Q: 窗口无法显示？

- 确认系统是 Ubuntu 24.04 桌面版（非服务器版）
- 确保已安装运行时依赖：`sudo apt install libgtk-3-0 libwebkit2gtk-4.1-0 libasound2`

### Q: 如何自定义数字人角色？

- 修改 `cfg.yml` 中的 `llm.name` 来改变数字人名字和性格
- 3D 模型可以通过替换 `web/models/avatar.vrm` 来更换（需要重新打包）

---

## 技术信息

| 组件 | 技术 |
|------|------|
| 语音识别 (ASR) | sherpa-onnx SenseVoiceSmall |
| 语音合成 (TTS) | sherpa-onnx Matcha-TTS + Vocos |
| 唤醒词检测 (KWS) | sherpa-onnx KWS Zipformer |
| 对话模型 | LLM HTTP 流式 API（OpenAI 兼容） |
| 3D 渲染 | three.js + three-vrm (WebGL) |
| 窗口 | GTK3 + WebKit2GTK |