#!/usr/bin/env bash
set -euo pipefail

# ── package.sh ────────────────────────────────────────────────────────
# 打包脚本：将 avatar-desktop 编译产物 + 模型文件 + 配置模板打包为 tar.gz
# 用法: ./package.sh [版本号]
# 产出: dist/avatar-desktop-<版本号>-linux-x86_64.tar.gz
#
# 注意: cfg.yml 从 cfg.yml.template 生成，绝不打包开发者自己的 cfg.yml。
# ───────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ── 0. 版本号（参数 > git 描述 > 默认） ────────────────────────────────
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  if git rev-parse --git-dir >/dev/null 2>&1; then
    VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo "dev")"
  else
    VERSION="dev"
  fi
fi

ARCH="$(uname -m)"
# x86_64 -> x86_64, aarch64 -> aarch64（与常见打包命名保持一致）
case "$ARCH" in
  x86_64)   ARCH="x86_64" ;;
  aarch64)  ARCH="aarch64" ;;
esac

PKG_NAME="avatar-desktop-${VERSION}-linux-${ARCH}"
DIST_DIR="dist/${PKG_NAME}"
ARCHIVE="dist/${PKG_NAME}.tar.gz"

# ── 1. 检查二进制文件 ─────────────────────────────────────────────────
if [[ ! -x "avatar-desktop" ]]; then
  echo "❌ avatar-desktop 不存在，请先运行 ./build.sh"
  exit 1
fi
if [[ ! -x "avatar-ui" ]]; then
  echo "❌ avatar-ui 不存在，请先运行 ./build.sh"
  exit 1
fi
echo "✔ 二进制文件就绪: avatar-desktop + avatar-ui"

# ── 2. 检查模型文件（与 README「最终 models/ 目录结构」一致） ─────────
MISSING_MODELS=()

# ASR
for f in models/asr/model.int8.onnx models/asr/tokens.txt; do
  [[ -f "$f" ]] || MISSING_MODELS+=("$f")
done

# TTS（sherpa-onnx 只读这 4 个文件，dict/ 与 *.fst 是 recipe 产物，运行不需要）
for f in models/tts/model.onnx models/tts/vocos.onnx \
         models/tts/tokens.txt models/tts/lexicon.txt; do
  [[ -f "$f" ]] || MISSING_MODELS+=("$f")
done

# KWS（findFile 按关键词匹配 encoder/decoder/joiner/tokens）
KWS_DIR="models/kws"
for kw in encoder decoder joiner; do
  found="$(find "$KWS_DIR" -maxdepth 1 -name "*${kw}*.onnx" -print -quit 2>/dev/null || true)"
  [[ -n "$found" ]] || MISSING_MODELS+=("models/kws/*${kw}*.onnx")
done
[[ -f "$KWS_DIR/tokens.txt" ]] || MISSING_MODELS+=("models/kws/tokens.txt")

if [[ ${#MISSING_MODELS[@]} -gt 0 ]]; then
  echo "❌ 缺少模型文件:"
  for f in "${MISSING_MODELS[@]}"; do
    echo "   - $f"
  done
  echo ""
  echo "   请参考 README.md 的「模型准备」章节下载模型。"
  exit 1
fi
echo "✔ 模型文件完整"

# ── 3. 创建发布目录 ───────────────────────────────────────────────────
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# ── 4. 复制二进制文件 ─────────────────────────────────────────────────
cp -v avatar-desktop "$DIST_DIR/"
cp -v avatar-ui       "$DIST_DIR/"
chmod +x "$DIST_DIR/avatar-desktop" "$DIST_DIR/avatar-ui"

# ── 5. 复制模型文件 ───────────────────────────────────────────────────
# ASR
mkdir -p "$DIST_DIR/models/asr"
cp models/asr/model.int8.onnx "$DIST_DIR/models/asr/"
cp models/asr/tokens.txt       "$DIST_DIR/models/asr/"

# TTS
mkdir -p "$DIST_DIR/models/tts"
cp models/tts/model.onnx  "$DIST_DIR/models/tts/"
cp models/tts/vocos.onnx  "$DIST_DIR/models/tts/"
cp models/tts/tokens.txt  "$DIST_DIR/models/tts/"
cp models/tts/lexicon.txt "$DIST_DIR/models/tts/"

# KWS（只复制 .int8.onnx 与 tokens.txt，跳过 test_wavs 与非 int8 变体）
mkdir -p "$DIST_DIR/models/kws"
cp models/kws/*.int8.onnx "$DIST_DIR/models/kws/" 2>/dev/null || true
cp models/kws/tokens.txt  "$DIST_DIR/models/kws/"
# 若不存在 int8 变体，回退复制任意 onnx
if ! compgen -G "$DIST_DIR/models/kws/*.int8.onnx" >/dev/null; then
  cp models/kws/*.onnx "$DIST_DIR/models/kws/" 2>/dev/null || true
fi

echo "✔ 模型文件已复制"

# ── 6. 生成配置文件（从模板，不包含开发者的 API key） ──────────────────
if [[ -f "cfg.yml.template" ]]; then
  cp cfg.yml.template "$DIST_DIR/cfg.yml"
  echo "✔ cfg.yml 已从 cfg.yml.template 生成（请编辑填入 LLM API 信息）"
else
  echo "⚠ 未找到 cfg.yml.template，跳过配置文件生成"
fi

# ── 7. 复制用户手册 ───────────────────────────────────────────────────
if [[ -f "USER_MANUAL.md" ]]; then
  cp USER_MANUAL.md "$DIST_DIR/"
  echo "✔ USER_MANUAL.md 已复制"
else
  echo "⚠ 未找到 USER_MANUAL.md，跳过"
fi

# ── 8. 打包 tar.gz ────────────────────────────────────────────────────
mkdir -p dist
tar czf "$ARCHIVE" -C dist "$PKG_NAME"

# 打包完成后清理解压目录，只保留 tar.gz
rm -rf "$DIST_DIR"
echo "✔ 已清理临时解压目录"

# ── 9. 输出摘要 ───────────────────────────────────────────────────────
ARCHIVE_SIZE="$(du -h "$ARCHIVE" | cut -f1)"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ 打包完成"
echo "════════════════════════════════════════════════════════════════"
echo "  文件:   ${ARCHIVE}"
echo "  大小:   ${ARCHIVE_SIZE}"
echo "  版本:   ${VERSION}"
echo "  平台:   linux/${ARCH}"
echo ""
echo "  内容:"
echo "    ├── avatar-desktop"
echo "    ├── avatar-ui"
echo "    ├── models/  (asr / tts / kws)"
echo "    ├── cfg.yml        (由模板生成，需自行填入 LLM API)"
echo "    └── USER_MANUAL.md  (用户手册)"
echo ""
echo "  部署到目标机器:"
echo "    scp ${ARCHIVE} user@target:/path/"
echo "    ssh user@target && cd /path"
echo "    tar xzf ${ARCHIVE}"
echo "    cd ${PKG_NAME}"
echo "    vi cfg.yml        # 填入 LLM API 信息"
echo "    ./avatar-desktop"
echo "════════════════════════════════════════════════════════════════"
