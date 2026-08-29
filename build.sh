#!/usr/bin/env bash
set -euo pipefail

# Cross-compiles every opencode target in a single pass.
#
# Bun compiles for all supported targets from one x64 Linux host, which is how
# opencode's own .github/workflows/publish.yml builds its releases. There is no
# per-architecture build: run this once, then package what you need.
#
# Only one output is kept downstream:
#
#   packages/opencode/dist/opencode-linux-arm64-android   aarch64, bionic
#
# That single binary serves both Termux variants -- stock Termux (apt) and
# termux-pacman both run on bionic libc. The glibc/musl/darwin/windows targets
# are compiled and discarded because build.ts takes no target filter; narrowing
# it would mean carrying a patch against a moving upstream branch.
#
# There is deliberately no 32-bit ARM build (Bun ships no armv7 binary) and no
# x64 bionic build (opencode's allTargets has exactly one android entry).
#
# Usage: ./build.sh <version>

VERSION="${1:?usage: build.sh <version>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${SCRIPT_DIR}/opencode"

if [ ! -d "${WORKDIR}" ]; then
  echo "ERROR: opencode source not found at ${WORKDIR}" >&2
  exit 1
fi

echo "=== Building opencode ${VERSION} (all targets) ==="

# Bun is normally provided by oven-sh/setup-bun in CI. Bootstrap it for local
# runs, pinning to the version opencode's package.json asks for -- script/build.ts
# refuses to run under anything outside ^<packageManager version>.
ensure_bun() {
  if command -v bun >/dev/null 2>&1; then
    echo "Using $(bun --version) from $(command -v bun)"
    return
  fi

  local want os cpu asset url tmp bun_bin
  want="$(sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"bun@\([^"]*\)".*/\1/p' "${WORKDIR}/package.json")"
  if [ -z "${want}" ]; then
    echo "ERROR: could not read packageManager from ${WORKDIR}/package.json" >&2
    exit 1
  fi

  case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="darwin" ;;
    *) echo "ERROR: unsupported host OS $(uname -s)" >&2; exit 1 ;;
  esac

  # Bun names its aarch64 asset "aarch64", not "arm64". Getting this wrong is
  # what produced the original 404.
  case "$(uname -m)" in
    x86_64 | amd64) cpu="x64" ;;
    aarch64 | arm64) cpu="aarch64" ;;
    *) echo "ERROR: unsupported host arch $(uname -m)" >&2; exit 1 ;;
  esac

  asset="bun-${os}-${cpu}"
  # Not every CI runner advertises AVX2; the baseline build is safe everywhere.
  [ "${cpu}" = "x64" ] && asset="${asset}-baseline"

  # Releases are .zip archives. There is no .tar.gz.
  url="https://github.com/oven-sh/bun/releases/download/bun-v${want}/${asset}.zip"
  tmp="$(mktemp -d)"

  echo "Installing bun ${want} from ${url}"
  curl -fsSL -o "${tmp}/bun.zip" "${url}"
  unzip -q "${tmp}/bun.zip" -d "${tmp}"

  bun_bin="$(find "${tmp}" -type f -name bun -perm -u+x | head -1)"
  if [ -z "${bun_bin}" ]; then
    echo "ERROR: no bun binary inside ${url}" >&2
    exit 1
  fi

  export PATH="$(dirname "${bun_bin}"):${PATH}"
  echo "Using $(bun --version) from ${bun_bin}"
}

ensure_bun

cd "${WORKDIR}"

# A full workspace install is mandatory: script/build.ts imports the
# @opencode-ai/script workspace package, and embedding the web UI shells out to
# a vite build in packages/app.
echo "Installing workspace dependencies..."
bun install

# Note the absence of --single and --skip-install:
#   --single       restricts the build to the *host* platform/arch, so it would
#                  never emit the arm64 or android binaries we are here for.
#   --skip-install skips the `bun install --os="*" --cpu="*"` that fetches the
#                  native deps (@opentui/core, @parcel/watcher, @ff-labs/fff-bun)
#                  for every target, which cross-compiling requires.
# script/build.ts takes no --target flag; targets come from its allTargets list.
echo "Compiling all targets..."
BUILD_ARGS=()
if [ -n "${SKIP_WEB_UI:-}" ]; then
  BUILD_ARGS+=(--skip-embed-web-ui)
fi

OPENCODE_VERSION="${VERSION}" bun run packages/opencode/script/build.ts ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}

echo "=== Build complete ==="
ls -la packages/opencode/dist/

# The android target exists only because patches/common/android-target.patch adds
# it -- upstream opencode has no bionic target at all. If that patch ever stops
# applying, all twelve other targets still build and this script would exit 0
# with nothing to ship. That is exactly how the first green-but-empty build
# happened, so assert the one output that matters.
ANDROID_BINARY="packages/opencode/dist/opencode-linux-arm64-android/bin/opencode"
if [ ! -f "${ANDROID_BINARY}" ]; then
  echo "ERROR: ${ANDROID_BINARY} was not produced." >&2
  echo "The android target is added by patches/common/android-target.patch." >&2
  echo "Verify that patch applied -- upstream has no bionic target of its own." >&2
  exit 1
fi

echo "Android binary: $(ls -la "${ANDROID_BINARY}")"
