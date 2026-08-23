# Avatar PC

基于 Go + three.js + three-vrm 的 3D 数字人，面向大屏/kiosk 场景。

**Go 做大脑（状态机、ASR/TTS/KWS、LLM 对话），WebKitGTK 做脸（three.js + three-vrm 渲染），中间 JS Bridge 通信。**



# 前提

- Ubuntu 24.04 桌面版
- `~/Desktop/siri_models/` 目录下已有模型文件（见下方「模型准备」）

# 1. C build



**（1）首次构建**

```bash
cd ~/workspace/avatar/pc
# avatar-ui（C 程序，需 WebKitGTK 开发库，放 Docker 里编译）
docker run -dit --name my_webkitgtk -v $(pwd):/workspace -w /workspace ubuntu:24.04

docker exec -it my_webkitgtk bash
apt update
# 中间需要手动输入时区之类的
apt install -y build-essential pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev
make avatar-ui
exit
# 提交保存镜像
docker commit my_webkitgtk avatar_webkit_gtk:1.0
docker stop my_webkitgtk
docker rm my_webkitgtk


```

**（2）后续构建**

```sh
docker run -dit --name my_webkitgtk -v $(pwd):/workspace -w /workspace avatar_webkit_gtk:1.0
docker exec -it my_webkitgtk bash
make avatar-ui
```

**（3）修改权限**

```sh
sudo chown rd:rd avatar-ui
```

最终产物：`avatar-ui`

# 2. 模型准备

在目录`~/siri_models/` 下准备以下文件：

```
siri_models/
├── sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar    # ASR
├── matcha-icefall-zh-baker.tar                                     # TTS
├── vocos-22khz-univ.onnx                                           # Vocoder
└── sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01.tar       # KWS
```

执行以下命令整理到 `models/`：

```bash
SRC=~/Desktop/siri_models
DST=models

# ASR
cd avatar/pc
mkdir -p $DST/asr
tar xf $SRC/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar \
    --strip-components=1 -C $DST/asr

# TTS
mkdir -p $DST/tts
tar xf $SRC/matcha-icefall-zh-baker.tar \
    --strip-components=1 -C $DST/tts
    
mv $DST/tts/model-steps-3.onnx $DST/tts/model.onnx

# Vocoder
cp $SRC/vocos-22khz-univ.onnx $DST/tts/vocos.onnx

# KWS
mkdir -p $DST/kws
tar xf $SRC/sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01.tar \
    --strip-components=1 -C $DST/kws

echo "Done."
```

最终 `models/` 目录结构：

```
models/
├── asr/
│   ├── model.int8.onnx
│   └── tokens.txt
├── tts/
│   ├── model.onnx                       # 由 model-steps-3.onnx 重命名
│   ├── vocos.onnx                        # 由 vocos-22khz-univ.onnx 重命名
│   ├── tokens.txt
│   └── lexicon.txt
└── kws/
    ├── encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx
    ├── decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx
    ├── joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx
    └── tokens.txt
```

# 3. go build

```sh
sudo apt update
sudo apt install -y pkg-config
# 语音输入（录音）的核心库
sudo apt install -y libasound2-dev
# 国内用户先设置代理
go env -w GOPROXY=https://goproxy.cn,direct   
./build.sh
```



最终产物：`avatar-ui` + `avatar-pc` 

# 4. 运行

```bash
# 进入工作目录
cd avatar/pc
# 创建配置文件
cp cfg.yml.template cfg.yml
# 填写相关模型信息
vi cfg.yml
./avatar-pc
```

## 4.1 项目结构

```
pc/
├── main.go                     # 入口
├── go.mod / go.sum
├── Makefile                    # avatar-ui 编译目标
├── build.sh                    # Go 编译脚本
├── cfg.yml                     # 配置文件
├── cmd/avatar-ui/main.c        # C 窗口宿主（GTK3 + WebKit2GTK）
├── internal/
│   ├── brain/                  # 状态机、情绪、viseme 映射
│   ├── asr/                    # sherpa-onnx ASR 引擎
│   ├── tts/                    # sherpa-onnx TTS 引擎
│   ├── kws/                    # sherpa-onnx 唤醒词引擎
│   ├── llm/                    # LLM HTTP 流式客户端
│   ├── audio/                  # 音频采集与播放
│   ├── config/                 # YAML 配置解析
│   └── renderer/               # 渲染器抽象 + Linux/Windows 实现
├── web/
│   ├── index.html              # 3D 渲染页面（three.js + three-vrm）
│   ├── js/                     # three.js / three-vrm / GLTFLoader
│   └── models/                 # VRM 模型
└── models/                     # 离线模型（不提交 git）
    ├── asr/
    ├── tts/
    └── kws/
```

## 4.2 技术栈

| 层 | 技术 |
|----|------|
| 后端 | C, Go, js |
| 窗口 | GTK3 + WebKit2GTK（Linux）、WebView2（Windows） |
| 3D 渲染 | three.js + three-vrm（WebGL） |
| ASR | sherpa-onnx SenseVoiceSmall int8 |
| TTS | sherpa-onnx Matcha-TTS + vocos |
| 唤醒词 | sherpa-onnx KWS Zipformer 3.3M |
| 对话 | LLM HTTP 流式 API（OpenAI 兼容） |
| 3D 模型 | VRM 格式（VRoid Studio 免费制作） |