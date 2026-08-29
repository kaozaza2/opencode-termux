#!/usr/bin/env bash
set -euo pipefail

# Build script for pacman variant (glibc + Bun available)
# Usage: ./build-pacman.sh <arch> <bun_arch> <version>

ARCH="${1:-aarch64}"
BUN_ARCH="${2:-arm64}"
VERSION="${3:-dev}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${SCRIPT_DIR}/opencode"
OUTDIR="${SCRIPT_DIR}/out"

mkdir -p "${OUTDIR}"

echo "=== Building opencode for pacman variant ==="
echo "Architecture: ${ARCH}"
echo "Bun architecture: ${BUN_ARCH}"
echo "Version: ${VERSION}"

# Clone or update opencode
if [ ! -d "${WORKDIR}/.git" ]; then
  echo "Cloning opencode..."
  git clone --depth 1 --branch "${VERSION}" https://github.com/anomalyco/opencode.git "${WORKDIR}"
else
  echo "Updating opencode..."
  cd "${WORKDIR}"
  git fetch --depth 1 origin "${VERSION}"
  git checkout FETCH_HEAD
fi

cd "${WORKDIR}"

# Apply variant-specific patches only (android target is already in upstream)
if [ -d "${SCRIPT_DIR}/patches/pacman" ]; then
  for patch in "${SCRIPT_DIR}/patches/pacman"/*.patch; do
    [ -f "$patch" ] && git apply "$patch" || true
  done
fi

# Install Bun for the target architecture
echo "Installing Bun..."
case "${BUN_ARCH}" in
  arm64)
    BUN_TARGET="linux-arm64"
    ;;
  arm)
    BUN_TARGET="linux-arm"
    ;;
  x64)
    BUN_TARGET="linux-x64"
    ;;
  *)
    echo "Unknown BUN_ARCH: ${BUN_ARCH}"
    exit 1
    ;;
esac

BUN_VERSION="bun-v1.4.0"
curl -fL "https://github.com/oven-sh/bun/releases/download/${BUN_VERSION}/bun-${BUN_TARGET}.tar.gz" | tar -xz -C /tmp
export PATH="/tmp/bun-${BUN_TARGET}:${PATH}"

# Install dependencies with Bun (cross-compile for target arch)
echo "Installing dependencies..."
cd packages/opencode
bun install --ignore-scripts --os="linux" --cpu="${BUN_ARCH}" \
  @opentui/core@0.4.5 \
  @parcel/watcher@2.5.1 \
  @ff-labs/fff-bun@0.9.4

# Build the binary
echo "Building binary..."
bun run script/build.ts --single --skip-install \
  --target="bun-linux-${BUN_ARCH}"

# Package the binary
BINARY_NAME="opencode-linux-${BUN_ARCH}-pacman"
DIST_DIR="dist/${BINARY_NAME}/bin"

if [ ! -f "${DIST_DIR}/opencode" ]; then
  echo "ERROR: Binary not found at ${DIST_DIR}/opencode"
  exit 1
fi

echo "Packaging..."
tar -czf "${OUTDIR}/${BINARY_NAME}-${VERSION}.tar.gz" -C "${DIST_DIR}" opencode

echo "=== Build complete ==="
echo "Output: ${OUTDIR}/${BINARY_NAME}-${VERSION}.tar.gz"
ls -la "${OUTDIR}/${BINARY_NAME}-${VERSION}.tar.gz"