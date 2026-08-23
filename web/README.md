# Avatar Web

基于 Go + three.js + three-vrm 的 3D 数字人 Web 版本。浏览器打开即用，支持全屏呈现。

## 前提

- 项目根目录 `avatar/` 下已有 `models/` 目录（离线模型文件）
- Ubuntu 24.04（服务端）

## 快速开始

```bash
# 1. 进入 web 目录
cd avatar/web

# 2. 配置
cp cfg.yml.template cfg.yml
# 编辑 cfg.yml，填入 LLM API 地址和密钥

# 3. 编译
make build         # 或: go build -o avatar-server .

# 4. 生成 HTTPS 证书（局域网其他设备访问需要）
./avatar-server -gen-cert
# 输出: cert.pem + key.pem

# 5. 启动
./avatar-server
# 浏览器打开 https://localhost:8080
```

## 配置说明

`cfg.yml`：

```yaml
llm:
  base_url: "https://api.deepseek.com"   # LLM API 地址
  api_key: "sk-xxx"                       # API 密钥
  model: "deepseek-v4-flash"              # 模型名称

wake_word: "x iǎo h uǒ x iǎo h uǒ @小火小火"

# ASR 语音识别
asr:
  mode: "offline"     # "offline" 本地 sherpa-onnx  /  "online" 云端 API
  base_url: ""        # online 模式需填写
  api_key: ""         # online 模式需填写
  model: "whisper-1"  # online 模式需填写

# TTS 语音合成
tts:
  mode: "offline"     # "offline" 本地 Matcha-TTS  /  "online" 云端 API
  base_url: ""        # online 模式需填写
  api_key: ""         # online 模式需填写
  model: "tts-1"      # online 模式需填写
  voice: "alloy"      # online 模式需填写

# HTTP 服务器
server:
  port: 8080
  # cert_file / key_file 无需手动填写，服务器自动检测 cert.pem + key.pem
```

## HTTPS 证书

浏览器要求 **HTTPS 或 localhost** 才允许使用麦克风（`getUserMedia`）。如果你用局域网其他设备访问（比如 `https://192.168.1.106:8080`），必须有 HTTPS。

### 生成自签名证书

```bash
./avatar-server -gen-cert
```

会自动检测本机所有局域网 IP，写入证书的 SAN（Subject Alternative Name），这样用 IP 地址访问也能通过证书校验。

### 启动

服务器启动时自动检测 `cert.pem` 和 `key.pem`：

- **两个文件都存在** → 以 `https://` 启动
- **不存在** → 以 `http://` 启动（仅 localhost 可用麦克风）

### 客户端信任证书（可选）

自签名证书浏览器会警告「不安全」。首次访问时点「高级 → 继续访问」即可正常使用。

如需永久消除警告，可以把 `cert.pem` 导入到客户端设备的受信任根证书：

- **Windows**：双击 `cert.pem` → 安装证书 → 受信任的根证书颁发机构
- **macOS**：拖入「钥匙串访问」→ 信任
- **Linux**：`sudo cp cert.pem /usr/local/share/ca-certificates/avatar.crt && sudo update-ca-certificates`

## 目录结构

```
web/
├── main.go                       # 入口
├── go.mod / go.sum
├── Makefile
├── cfg.yml / cfg.yml.template    # 配置文件
├── internal/
│   ├── brain/                    # 状态机、情绪、口型映射
│   ├── asr/                      # ASR 引擎 (offline/online)
│   ├── tts/                      # TTS 引擎 (offline/online)
│   ├── kws/                      # 唤醒词引擎
│   ├── llm/                      # LLM HTTP 流式客户端
│   ├── config/                   # YAML 配置解析
│   ├── transport/                # WebSocket 传输层
│   ├── wav/                      # WAV 编解码
│   └── certgen/                  # 自签名证书生成
├── web/                          # 前端静态文件
│   ├── index.html                # 3D 渲染 + WebSocket + Web Audio
│   ├── js/                       # three.js / three-vrm
│   └── models/                   # VRM 模型 + FBX 动画
└── models/ -> ../desktop/models/      # 符号链接到离线模型
```

## WebSocket 协议

浏览器与服务器之间的实时通信协议（`/ws` 端点，JSON 消息）：

```
浏览器 → 服务器:
  {"type":"audio","data":[...]}   // PCM float32 音频数据（麦克风采集）
  {"type":"tap"}                   // 用户点击 / 键盘触发
  {"type":"ping"}                  // 心跳

服务器 → 浏览器:
  {"mode":"idle","emotion":"neutral","isSpeaking":false}  // 状态更新
  {"type":"viseme_timeline","timeline":[...]}              // 口型同步
  {"samples":[...],"sampleRate":22050}                     // TTS 音频
  {"type":"pong"}                                           // 心跳回复
```

## 技术栈

| 层 | 技术 |
|----|------|
| 后端 | Go |
| 3D 渲染 | three.js + three-vrm (WebGL) |
| 通信 | WebSocket |
| 音频采集 | Web Audio API (`getUserMedia`) |
| 音频播放 | Web Audio API (`AudioContext`) |
| ASR | sherpa-onnx SenseVoiceSmall / OpenAI Whisper |
| TTS | sherpa-onnx Matcha-TTS / OpenAI TTS |
| 唤醒词 | sherpa-onnx KWS Zipformer |
| 对话 | LLM HTTP 流式 API (OpenAI 兼容) |
| 3D 模型 | VRM 格式 |

