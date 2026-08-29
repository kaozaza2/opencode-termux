#!/usr/bin/env bash
set -euo pipefail

# Packages the already-built opencode Android binary into a Termux tarball.
# Compiles nothing -- run build.sh first, or restore its artifact.
#
# Usage: ./package.sh <termux_arch> <variant> <version>
#
# Both Termux package managers run on bionic libc, so stock Termux (apt) and
# termux-pacman take the same binary and only the tarball name differs.
# Upstream smoke-tests opencode-linux-arm64-android inside the
# termux/termux-docker-pacman image for exactly this reason.

ARCH="${1:?usage: package.sh <termux_arch> <variant> <version>}"
VARIANT="${2:?usage: package.sh <termux_arch> <variant> <version>}"
VERSION="${3:?usage: package.sh <termux_arch> <variant> <version>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTDIR="${DISTDIR:-${SCRIPT_DIR}/opencode/packages/opencode/dist}"
OUTDIR="${SCRIPT_DIR}/out"

# opencode's allTargets contains exactly one bionic entry, linux/arm64. There is
# no 32-bit ARM build (Bun ships no armv7 binary) and no x64 android target.
case "${ARCH}-${VARIANT}" in
  aarch64-apt | aarch64-pacman) DIST_NAME="opencode-linux-arm64-android" ;;
  *)
    echo "ERROR: no opencode android target for ${ARCH}-${VARIANT}" >&2
    echo "Supported: aarch64-apt, aarch64-pacman" >&2
    exit 1
    ;;
esac

# After a local build the binary sits at <dist>/<target>/bin/opencode, but CI
# downloads it from an artifact that was uploaded as a single file and so keeps
# only the leaf. Accept either shape.
BINARY=""
for candidate in \
  "${DISTDIR}/${DIST_NAME}/bin/opencode" \
  "${DISTDIR}/bin/opencode" \
  "${DISTDIR}/opencode"; do
  if [ -f "${candidate}" ]; then
    BINARY="${candidate}"
    break
  fi
done

if [ -z "${BINARY}" ]; then
  echo "ERROR: no ${DIST_NAME} binary found under ${DISTDIR}" >&2
  echo "Contents:" >&2
  find "${DISTDIR}" -maxdepth 3 >&2 2>/dev/null || true
  exit 1
fi

echo "=== Packaging ${ARCH}-${VARIANT} from ${BINARY} ==="
# Artifact zips do not preserve the executable bit.
chmod +x "${BINARY}"
file "${BINARY}" || true

mkdir -p "${OUTDIR}"
TARBALL="${OUTDIR}/opencode-${VERSION}-${ARCH}-${VARIANT}.tar.gz"
tar -czf "${TARBALL}" -C "$(dirname "${BINARY}")" opencode

echo "=== Packaged ==="
ls -la "${TARBALL}"
