#!/usr/bin/env bash
set -euo pipefail

# Build script for apt variant (bionic libc, NO Bun)
# Usage: ./build-apt.sh <arch> <bun_arch> <version>
# 
# Since Bun is not available for apt/bionic, we use a different approach:
# 1. Build on host (x86_64) using Bun with cross-compilation
# 2. The resulting binary will use bionic libc via android target

ARCH="${1:-aarch64}"
BUN_ARCH="${2:-arm64}"
VERSION="${3:-dev}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${SCRIPT_DIR}/opencode"
OUTDIR="${SCRIPT_DIR}/out"

mkdir -p "${OUTDIR}"

echo "=== Building opencode for apt variant (bionic libc) ==="
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
if [ -d "${SCRIPT_DIR}/patches/apt" ]; then
  for patch in "${SCRIPT_DIR}/patches/apt"/*.patch; do
    [ -f "$patch" ] && git apply "$patch" || true
  done
fi

# Install Bun on host for cross-compilation
echo "Installing host Bun..."
BUN_VERSION="bun-v1.4.0"
curl -fL "https://github.com/oven-sh/bun/releases/download/${BUN_VERSION}/bun-linux-x64.tar.gz" | tar -xz -C /tmp
export PATH="/tmp/bun-linux-x64:${PATH}"

# Install dependencies for cross-compilation
echo "Installing dependencies..."
cd packages/opencode
bun install --ignore-scripts --os="linux" --cpu="${BUN_ARCH}" \
  @opentui/core@0.4.5 \
  @parcel/watcher@2.5.1 \
  @ff-labs/fff-bun@0.9.4

# Build the binary targeting bionic libc using android target
echo "Building binary for bionic libc..."
case "${BUN_ARCH}" in
  arm64)
    BUN_COMPILE_TARGET="bun-linux-arm64-android"
    ;;
  arm)
    BUN_COMPILE_TARGET="bun-linux-arm-android"
    ;;
  x64)
    BUN_COMPILE_TARGET="bun-linux-x64-android"
    ;;
  *)
    echo "Unknown BUN_ARCH: ${BUN_ARCH}"
    exit 1
    ;;
esac

bun run script/build.ts --single --skip-install \
  --target="${BUN_COMPILE_TARGET}"

# The binary name will include "android" in it
BINARY_NAME_ANDROID="opencode-linux-${BUN_ARCH}-android"
DIST_DIR_ANDROID="dist/${BINARY_NAME_ANDROID}/bin"

if [ ! -f "${DIST_DIR_ANDROID}/opencode" ]; then
  echo "ERROR: Binary not found at ${DIST_DIR_ANDROID}/opencode"
  echo "Available dist dirs:"
  ls -la dist/
  exit 1
fi

# Rename for apt variant (remove android suffix)
APT_BINARY_NAME="opencode-linux-${BUN_ARCH}-apt"
APT_DIST_DIR="dist/${APT_BINARY_NAME}/bin"

mkdir -p "${APT_DIST_DIR}"
cp "${DIST_DIR_ANDROID}/opencode" "${APT_DIST_DIR}/opencode"

# Verify it runs
echo "Verifying binary..."
"${APT_DIST_DIR}/opencode" --version || true

# Package the binary
echo "Packaging..."
tar -czf "${OUTDIR}/${APT_BINARY_NAME}-${VERSION}.tar.gz" -C "${APT_DIST_DIR}" opencode

echo "=== Build complete ==="
echo "Output: ${OUTDIR}/${APT_BINARY_NAME}-${VERSION}.tar.gz"
ls -la "${OUTDIR}/${APT_BINARY_NAME}-${VERSION}.tar.gz"