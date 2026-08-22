#!/usr/bin/env bash
#
# pc/scripts/download-models.sh
# 下载 PC 数字人所需的 sherpa-onnx 离线模型到 pc/models/
#
# 用法:
#   chmod +x download-models.sh
#   ./download-models.sh              # 下载全部
#   ./download-models.sh --asr-only   # 仅下载 ASR
#   ./download-models.sh --tts-only   # 仅下载 TTS + vocoder
#   ./download-models.sh --kws-only   # 仅下载 KWS
#
# 总下载量: ~294 MB (ASR 158MB + TTS 72MB + vocoder 51MB + KWS 13MB)

set -euo pipefail

# ============================================================
# 模型 URL（与 Android 端 ModelManager.kt 完全一致）
# ============================================================

# ASR: SenseVoiceSmall int8 量化版
ASR_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2"
ASR_FILE="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2"

# TTS: Matcha-TTS 中文女声（注意：是 Matcha，不是 VITS！PC 代码用的 Matcha）
TTS_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/matcha-icefall-zh-baker.tar.bz2"
TTS_FILE="matcha-icefall-zh-baker.tar.bz2"

# Vocoder: vocos-22khz-univ（Matcha 需要单独下载声码器）
VOCODER_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/vocoder-models/vocos-22khz-univ.onnx"
VOCODER_FILE="vocos-22khz-univ.onnx"

# KWS: Zipformer WenetSpeech 3.3M 唤醒词检测
KWS_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01.tar.bz2"
KWS_FILE="sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01.tar.bz2"

# ============================================================
# 路径
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PC_DIR="$(dirname "$SCRIPT_DIR")"
MODELS_DIR="${PC_DIR}/models"
CACHE_DIR="${SCRIPT_DIR}/.model_cache"

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
            echo "  (无参数)    下载全部: ASR + TTS + vocoder + KWS"
            echo "  --asr-only  仅下载 ASR 模型 (SenseVoiceSmall int8, ~158MB)"
            echo "  --tts-only  仅下载 TTS 模型 + vocoder (Matcha-TTS, ~123MB)"
            echo "  --kws-only  仅下载 KWS 唤醒词模型 (Zipformer 3.3M, ~13MB)"
            echo ""
            echo "  模型将安装到: ${MODELS_DIR}/asr/  ${MODELS_DIR}/tts/  ${MODELS_DIR}/kws/"
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
    # bunzip2 is needed for .tar.bz2
    if ! command -v bunzip2 &>/dev/null && ! command -v bzip2 &>/dev/null; then
        missing+=("bunzip2/bzip2")
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "缺少依赖: ${missing[*]}"
        echo "  Ubuntu/Debian: sudo apt install curl bzip2 tar"
        echo "  RHEL/Fedora:   sudo dnf install curl bzip2 tar"
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
    echo
    log_info "下载完成: ${output}"
}

# ============================================================
# 去重命名（与 Android ModelManager.RENAME_MAP 一致）
# ============================================================
normalize_names() {
    local dir="$1"

    # TTS: model-steps-3.onnx -> model.onnx
    if [ -f "${dir}/model-steps-3.onnx" ] && [ ! -f "${dir}/model.onnx" ]; then
        mv "${dir}/model-steps-3.onnx" "${dir}/model.onnx"
        log_info "重命名: model-steps-3.onnx → model.onnx"
    fi

    # Vocoder: vocos-22khz-univ.onnx -> vocos.onnx
    if [ -f "${dir}/vocos-22khz-univ.onnx" ] && [ ! -f "${dir}/vocos.onnx" ]; then
        mv "${dir}/vocos-22khz-univ.onnx" "${dir}/vocos.onnx"
        log_info "重命名: vocos-22khz-univ.onnx → vocos.onnx"
    fi

    # KWS: long names -> short names
    for f in "${dir}"/encoder-*.onnx; do
        [ -f "$f" ] && [ ! -f "${dir}/encoder.onnx" ] && mv "$f" "${dir}/encoder.onnx" && log_info "重命名: $(basename "$f") → encoder.onnx" && break
    done
    for f in "${dir}"/decoder-*.onnx; do
        [ -f "$f" ] && [ ! -f "${dir}/decoder.onnx" ] && mv "$f" "${dir}/decoder.onnx" && log_info "重命名: $(basename "$f") → decoder.onnx" && break
    done
    for f in "${dir}"/joiner-*.onnx; do
        [ -f "$f" ] && [ ! -f "${dir}/joiner.onnx" ] && mv "$f" "${dir}/joiner.onnx" && log_info "重命名: $(basename "$f") → joiner.onnx" && break
    done
}

# ============================================================
# 主流程
# ============================================================

echo ""
echo "=============================================="
echo "  Avatar PC 离线模型下载"
echo "=============================================="
echo ""
echo "  下载内容:"
$DO_ASR && echo "    - ASR 模型 (SenseVoiceSmall int8, ~158 MB)"
$DO_TTS && echo "    - TTS 模型 (Matcha-TTS zh-baker, ~72 MB)"
$DO_TTS && echo "    - Vocoder  (vocos-22khz-univ, ~51 MB)"
$DO_KWS && echo "    - KWS 唤醒词 (Zipformer 3.3M, ~13 MB)"
echo ""
echo "  安装目录: ${MODELS_DIR}"
echo ""

check_deps
mkdir -p "$CACHE_DIR"

# ---- ASR ----
if $DO_ASR; then
    echo "---"
    log_step "下载 ASR 模型 (SenseVoiceSmall int8)"
    download_file "$ASR_URL" "${CACHE_DIR}/${ASR_FILE}" "ASR 模型"

    log_info "解压到 ${MODELS_DIR}/asr/"
    mkdir -p "${MODELS_DIR}/asr"
    tar xf "${CACHE_DIR}/${ASR_FILE}" --strip-components=1 -C "${MODELS_DIR}/asr"
    normalize_names "${MODELS_DIR}/asr"
    log_info "ASR 模型就绪"
fi

# ---- TTS + Vocoder ----
if $DO_TTS; then
    echo "---"
    log_step "下载 TTS 模型 (Matcha-TTS zh-baker)"
    download_file "$TTS_URL" "${CACHE_DIR}/${TTS_FILE}" "Matcha-TTS 模型"

    log_info "解压到 ${MODELS_DIR}/tts/"
    mkdir -p "${MODELS_DIR}/tts"
    tar xf "${CACHE_DIR}/${TTS_FILE}" --strip-components=1 -C "${MODELS_DIR}/tts"

    echo "---"
    log_step "下载 Vocoder (vocos-22khz-univ)"
    download_file "$VOCODER_URL" "${CACHE_DIR}/${VOCODER_FILE}" "Vocoder"

    log_info "复制 vocoder 到 ${MODELS_DIR}/tts/"
    cp "${CACHE_DIR}/${VOCODER_FILE}" "${MODELS_DIR}/tts/${VOCODER_FILE}"

    normalize_names "${MODELS_DIR}/tts"
    log_info "TTS 模型就绪"
fi

# ---- KWS ----
if $DO_KWS; then
    echo "---"
    log_step "下载 KWS 唤醒词模型 (Zipformer 3.3M)"
    download_file "$KWS_URL" "${CACHE_DIR}/${KWS_FILE}" "KWS 模型"

    log_info "解压到 ${MODELS_DIR}/kws/"
    mkdir -p "${MODELS_DIR}/kws"
    tar xf "${CACHE_DIR}/${KWS_FILE}" --strip-components=1 -C "${MODELS_DIR}/kws"

    normalize_names "${MODELS_DIR}/kws"
    log_info "KWS 唤醒词模型就绪"
fi

# ============================================================
# 验证
# ============================================================
echo ""
echo "=============================================="
echo "  验证模型文件"
echo "=============================================="
echo ""

verify_file() {
    local path="$1"
    local label="$2"
    if [ -f "$path" ]; then
        local size=$(du -h "$path" 2>/dev/null | cut -f1)
        echo -e "  ${GREEN}✓${NC} ${label}  (${size})"
    else
        echo -e "  ${RED}✗${NC} ${label}  — 缺失!"
    fi
}

if $DO_ASR; then
    echo "  ASR (${MODELS_DIR}/asr/):"
    verify_file "${MODELS_DIR}/asr/model.int8.onnx" "model.int8.onnx"
    verify_file "${MODELS_DIR}/asr/tokens.txt"      "tokens.txt"
    echo ""
fi

if $DO_TTS; then
    echo "  TTS (${MODELS_DIR}/tts/):"
    verify_file "${MODELS_DIR}/tts/model.onnx"   "model.onnx"
    verify_file "${MODELS_DIR}/tts/vocos.onnx"   "vocos.onnx"
    verify_file "${MODELS_DIR}/tts/tokens.txt"   "tokens.txt"
    verify_file "${MODELS_DIR}/tts/lexicon.txt"  "lexicon.txt"
    echo ""
fi

if $DO_KWS; then
    echo "  KWS (${MODELS_DIR}/kws/):"
    verify_file "${MODELS_DIR}/kws/encoder.onnx" "encoder.onnx"
    verify_file "${MODELS_DIR}/kws/decoder.onnx" "decoder.onnx"
    verify_file "${MODELS_DIR}/kws/joiner.onnx"  "joiner.onnx"
    verify_file "${MODELS_DIR}/kws/tokens.txt"   "tokens.txt"
    echo ""
fi

echo "=============================================="
echo "  完成"
echo "=============================================="
echo ""
echo "  模型目录结构:"
echo "    ${MODELS_DIR}/"
echo "      asr/"
echo "        model.int8.onnx"
echo "        tokens.txt"
echo "      tts/"
echo "        model.onnx"
echo "        vocos.onnx"
echo "        tokens.txt"
echo "        lexicon.txt"
echo "      kws/"
echo "        encoder.onnx"
echo "        decoder.onnx"
echo "        joiner.onnx"
echo "        tokens.txt"
echo ""
echo "  下一步:"
echo "    cd pc && make run"
echo ""