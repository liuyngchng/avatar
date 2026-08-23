#!/usr/bin/env bash
set -euo pipefail

# ─── 1. Check we're in the pc directory ──────────────────────────
if [[ ! -f "main.go" ]] || [[ ! -f "go.mod" ]]; then
  echo "❌ ERROR: run this script from the desktop/ directory"
  exit 1
fi
echo "✔ OK: current directory = $(pwd)"

# ─── 2. Check docker is available ────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo "❌ ERROR: docker not found, please install Docker first"
  exit 1
fi
echo "✔ OK: docker found"

# ─── 3. Check the build image exists ─────────────────────────────
IMAGE="avatar_webkit_gtk:1.0"
if ! docker image inspect "$IMAGE" &>/dev/null; then
  echo "❌ ERROR: Docker image $IMAGE does not exist"
  echo "       build it first (see README.md for instructions)"
  exit 1
fi
echo "✔ OK: image $IMAGE ready"

# ─── 4. Build avatar-ui (C) in Docker ────────────────────────────
echo "🔨 Building avatar-ui (in Docker)..."
docker run --rm -v "$(pwd)":/workspace -w /workspace "$IMAGE" make avatar-ui
echo "✔ OK: avatar-ui built"

# ─── 5. Build avatar-desktop (Go) ─────────────────────────────────────
echo "🔨 Building avatar-desktop..."
go build -o avatar-desktop .
echo "✔ OK: avatar-desktop built"

echo ""
echo "✅ Done: avatar-ui + avatar-desktop"