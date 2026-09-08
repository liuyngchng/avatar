#!/usr/bin/env bash
#
# download-models.sh — 下载 sherpa-onnx 离线 ASR/TTS/KWS 模型
#
# 用法:
#   chmod +x download-models.sh
#   ./download-models.sh              # 下载全部
#   ./download-models.sh --asr-only   # 仅下载 ASR 模型
#   ./download-models.sh --tts-only   # 仅下载 TTS 模型
#   ./download-models.sh --kws-only   # 仅下载 KWS 唤醒词模型
#
# 下载后的文件放在 desktop/models/ 目录下，结构与 README 一致。

set -euo pipefail

# ============================================================
# 配置区
# ============================================================

# ASR: SenseVoiceSmall int8 量化版
ASR_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2"
ASR_FILE="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2"

# TTS: Matcha-icefall-zh-baker (Chinese Matcha-TTS)
TTS_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/matcha-icefall-zh-baker.tar.bz2"
TTS_FILE="matcha-icefall-zh-baker.tar.bz2"

# Vocoder for Matcha-TTS
VOCODER_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/vocoder-models/vocos-22khz-univ.onnx"
VOCODER_FILE="vocos-22khz-univ.onnx"

# KWS: 关键词检测 (Zipformer WenetSpeech 3.3M，支持中文唤醒词)
KWS_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01.tar.bz2"
KWS_FILE="sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01.tar.bz2"

# ============================================================
# 路径
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESKTOP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOWNLOAD_DIR="${DESKTOP_DIR}/models/.cache"
MODELS_DIR="${DESKTOP_DIR}/models"

# ============================================================
# 参数解析
# ============================================================
DO_ASR=true
DO_TTS=true
DO_KWS=true

for arg in "$@"; do
    case "$arg" in
        --asr-only) DO_TTS=false; DO_KWS=false ;;
        --tts-only) DO_ASR=false; DO_KWS=false ;;
        --kws-only) DO_ASR=false; DO_TTS=false ;;
        --help|-h)
            echo "用法: $0 [--asr-only|--tts-only|--kws-only]"
            echo ""
            echo "  (无参数)    下载全部: ASR + TTS + KWS"
            echo "  --asr-only  仅下载 ASR 模型"
            echo "  --tts-only  仅下载 TTS 模型 (含 vocoder)"
            echo "  --kws-only  仅下载 KWS 唤醒词模型"
            exit 0
            ;;
        *)
            echo "未知参数: $arg"
            echo "用法: $0 [--asr-only|--tts-only|--kws-only]"
            exit 1
            ;;
    esac
done

# ============================================================
# 工具函数
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }

check_deps() {
    local missing=()
    for cmd in curl tar; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "缺少依赖: ${missing[*]}"
        exit 1
    fi
}

download_file() {
    local url="$1"
    local output="$2"
    local description="$3"

    if [ -f "$output" ]; then
        log_warn "文件已存在: ${output}"
        read -p "  是否重新下载? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "跳过下载"
            return 0
        fi
    fi

    log_info "下载 ${description}..."
    log_info "  URL: ${url}"
    curl -L --progress-bar -o "$output" "$url"
    log_info "下载完成: ${output}"
}

# ============================================================
# 主流程
# ============================================================

echo ""
echo "=============================================="
echo "  Avatar PC 模型下载"
echo "=============================================="
echo ""
echo "  下载内容:"
$DO_ASR && echo "    - ASR 模型 (SenseVoiceSmall int8, ~94 MB)"
$DO_TTS && echo "    - TTS 模型 (Matcha-icefall-zh-baker, ~23 MB)"
$DO_TTS && echo "    - Vocoder (vocos-22khz-univ, ~50 MB)"
$DO_KWS && echo "    - KWS 唤醒词模型 (Zipformer 3.3M, ~13 MB)"
echo ""
echo "  下载缓存: ${DOWNLOAD_DIR}"
echo "  模型目录: ${MODELS_DIR}"
echo ""

check_deps
mkdir -p "$DOWNLOAD_DIR"
mkdir -p "$MODELS_DIR/asr"
mkdir -p "$MODELS_DIR/tts"
mkdir -p "$MODELS_DIR/kws"

# ---- ASR ----
if $DO_ASR; then
    echo "---"
    log_step "下载 ASR 模型"
    download_file "$ASR_URL" "${DOWNLOAD_DIR}/${ASR_FILE}" "SenseVoiceSmall int8"
    log_info "解压 ASR 模型..."
    tar xf "${DOWNLOAD_DIR}/${ASR_FILE}" --strip-components=1 -C "$MODELS_DIR/asr"
    log_info "ASR 模型就绪: $MODELS_DIR/asr/"
fi

# ---- TTS ----
if $DO_TTS; then
    echo "---"
    log_step "下载 TTS 模型"
    download_file "$TTS_URL" "${DOWNLOAD_DIR}/${TTS_FILE}" "Matcha-icefall-zh-baker"
    log_info "解压 TTS 模型..."
    tar xf "${DOWNLOAD_DIR}/${TTS_FILE}" --strip-components=1 -C "$MODELS_DIR/tts"

    # Rename model-steps-3.onnx -> model.onnx (standard name)
    if [ -f "$MODELS_DIR/tts/model-steps-3.onnx" ]; then
        mv "$MODELS_DIR/tts/model-steps-3.onnx" "$MODELS_DIR/tts/model.onnx"
        log_info "TTS: renamed model-steps-3.onnx -> model.onnx"
    fi

    log_step "下载 Vocoder"
    download_file "$VOCODER_URL" "${DOWNLOAD_DIR}/${VOCODER_FILE}" "vocos-22khz-univ"
    cp "${DOWNLOAD_DIR}/${VOCODER_FILE}" "$MODELS_DIR/tts/vocos.onnx"
    log_info "TTS 模型就绪: $MODELS_DIR/tts/"
fi

# ---- KWS ----
if $DO_KWS; then
    echo "---"
    log_step "下载 KWS 唤醒词模型"
    download_file "$KWS_URL" "${DOWNLOAD_DIR}/${KWS_FILE}" "KWS Zipformer 3.3M"
    log_info "解压 KWS 模型..."
    tar xf "${DOWNLOAD_DIR}/${KWS_FILE}" --strip-components=1 -C "$MODELS_DIR/kws"
    log_info "KWS 唤醒词模型就绪: $MODELS_DIR/kws/"
fi

# ============================================================
# 完成
# ============================================================
echo ""
echo "=============================================="
echo "  下载完成"
echo "=============================================="
echo ""
echo "  模型目录: $MODELS_DIR"
echo ""
echo "  最终结构:"
echo "    models/"
echo "    ├── asr/"
echo "    │   ├── model.int8.onnx"
echo "    │   └── tokens.txt"
echo "    ├── tts/"
echo "    │   ├── model.onnx"
echo "    │   ├── vocos.onnx"
echo "    │   ├── tokens.txt"
echo "    │   └── lexicon.txt"
echo "    └── kws/"
echo "        ├── encoder-*.int8.onnx"
echo "        ├── decoder-*.onnx"
echo "        ├── joiner-*.int8.onnx"
echo "        └── tokens.txt"
echo ""
echo "  下一步: 配置 cfg.yml 并运行 ./avatar-desktop"
echo ""
log_info "全部就绪!"