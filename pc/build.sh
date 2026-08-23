#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# ─── Check avatar-ui ──────────────────────────────────────────
if [ ! -f avatar-ui ]; then
  echo "⚠️  avatar-ui not found (C binary, needs WebKitGTK to compile)."
  echo "   Build it in Docker:"
  echo ""
  echo "   docker run --rm -v \$(pwd):/workspace -w /workspace ubuntu:24.04 bash -c '"
  echo "     apt update && apt install -y build-essential pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev &&"
  echo "     make avatar-ui"
  echo "   '"
  echo ""
fi

# ─── Build Go backend ─────────────────────────────────────────
echo "Building avatar-pc..."
go build -o avatar-pc .
echo "✔ avatar-pc built"