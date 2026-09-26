#!/usr/bin/env bash
set -euo pipefail

# ./package.sh [version] -- tarballs an already-built binary. Compiles nothing;
# run build.sh first. The version defaults to what build.ts recorded in the
# artifact's package.json, except after a CI upload, which flattens that.

VERSION="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTDIR="${DISTDIR:-${SCRIPT_DIR}/opencode/packages/cli/dist}"
OUTDIR="${SCRIPT_DIR}/out"

# The only bionic target android-target.patch adds. arm64 only: Bun ships no
# armv7 runtime and there is no x64 bionic target.
DIST_NAME="cli-linux-arm64-android"

# A local build keeps the dist layout; a CI artifact upload keeps only the leaf.
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

if [ -z "${VERSION}" ]; then
  MANIFEST="${DISTDIR}/${DIST_NAME}/package.json"
  if [ -f "${MANIFEST}" ]; then
    VERSION="$(node -e 'process.stdout.write(String(require(process.argv[1]).version ?? ""))' "${MANIFEST}")"
  fi
  if [ -z "${VERSION}" ]; then
    echo "ERROR: no version given and none in ${MANIFEST}." >&2
    exit 1
  fi
  echo "Using version ${VERSION} from ${MANIFEST}"
fi

echo "=== Packaging ${DIST_NAME} as opencode-termux-${VERSION} ==="
# Artifact uploads lose the executable bit.
chmod +x "${BINARY}"
file "${BINARY}" || true

mkdir -p "${OUTDIR}"
TARBALL="${OUTDIR}/opencode-termux-${VERSION}.tar.gz"
tar -czf "${TARBALL}" -C "$(dirname "${BINARY}")" opencode

echo "=== Packaged ==="
ls -la "${TARBALL}"
