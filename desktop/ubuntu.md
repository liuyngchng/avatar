# Ubuntu 24.04 LTS 构建与部署

## 概述

项目由两部分组成：

| 组件 | 语言 | 说明 |
|------|------|------|
| `avatar-ui` | C | 窗口宿主（GTK3 + WebKit2GTK），负责透明窗口和 WebGL 渲染 |
| `avatar-desktop` | Go | 后端主程序，ASR/TTS/KWS/LLM 引擎，音频 I/O，状态机 |

`avatar-ui` 编译需要 WebKitGTK 开发库，折腾起来麻烦。**C 编译放 Docker 里做，Go 编译本地做。**

---

## 一、编译 avatar-ui（C，在 Docker 里）

在项目根目录执行：

```bash
# 启动 Ubuntu 24.04 容器，挂载当前目录，编译 C 二进制
docker run --rm -v $(pwd):/workspace -w /workspace ubuntu:24.04 bash -c '
  apt update &&
  apt install -y build-essential pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev &&
  make avatar-ui
'
```

编译完成后 `avatar-ui` 直接出现在项目根目录。

> 这个二进制只依赖运行时库（`libwebkit2gtk-4.1-0`、`libgtk-3-0`），Ubuntu 24.04 桌面版通常已自带。**不需要在目标机上装 `-dev` 包。**

---

## 二、编译 avatar-desktop（Go，本地）

Go 编译只需 ALSA 开发头文件，安装后直接 `make` 或 `go build`：

```bash
sudo apt install libasound2-dev
make avatar-desktop
# 或: go build -o avatar-desktop .
```

---

## 三、运行时依赖

目标机器（Ubuntu 24.04 桌面版）通常已自带以下运行时包，无需额外安装：

```
libgtk-3-0
libwebkit2gtk-4.1-0
libasound2
```

如果缺失，运行：

```bash
sudo apt install libgtk-3-0 libwebkit2gtk-4.1-0 libasound2
```

---

## 四、一键构建（完整）

```bash
# 1. Docker 编译 C
docker run --rm -v $(pwd):/workspace -w /workspace ubuntu:24.04 bash -c '
  apt update && apt install -y build-essential pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev &&
  make avatar-ui
'

# 2. 本地编译 Go
sudo apt install libasound2-dev
make avatar-desktop
```

产物：`./avatar-ui` + `./avatar-desktop`，在同目录下放进 `web/` 和 `models/` 即可运行。