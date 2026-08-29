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

# The Bun that compiles is the Bun that gets embedded: `bun build --compile`
# bakes its own runtime into the binary. So this version is a *runtime* choice
# for the shipped binary, not just a build-tool choice.
#
# Deliberately NOT opencode's packageManager pin (1.3.14). That runtime
# segfaults at startup on arm64 bionic, inside the JS parser lowering `using`
# declarations (js_parser P.zig LowerUsingDeclarationsContext.finalize), before
# the runtime finishes initialising. 1.4.0 does not.
#
# Must still satisfy the `^<packageManager>` range that script/build.ts enforces;
# it throws with a clear message if not. Override to bisect Bun regressions.
BUN_VERSION="${BUN_VERSION:-1.4.0}"

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
    local have
    have="$(bun --version)"
    echo "Using bun ${have} from $(command -v bun)"
    if [ "${have}" != "${BUN_VERSION}" ]; then
      echo "WARNING: bun ${have} on PATH but this build targets ${BUN_VERSION}." >&2
      echo "The binary embeds the runtime of whichever bun compiles it." >&2
    fi
    return
  fi

  local want os cpu asset url tmp bun_bin
  want="${BUN_VERSION}"

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

# script/build.ts installs the native deps (--os="*" --cpu="*") right before it
# compiles. Running the exact same installs here first makes those later runs
# no-ops: they must NOT re-extract @opentui/core from the bun store and undo the
# bionic fixes applied by prepare_opentui_android.
prewarm_native_deps() {
  local core parcel fff
  core="$(bun -e 'console.log(require("./packages/opencode/package.json").dependencies["@opentui/core"])')"
  parcel="$(bun -e 'console.log(require("./packages/opencode/package.json").dependencies["@parcel/watcher"])')"
  fff="$(bun -e 'console.log(require("./packages/opencode/package.json").dependencies["@ff-labs/fff-bun"])')"
  bun install --os="*" --cpu="*" "@opentui/core@${core}"
  bun install --os="*" --cpu="*" "@parcel/watcher@${parcel}"
  bun install --os="*" --cpu="*" "@ff-labs/fff-bun@${fff}"
}

# Two things stand between a cross-compiled android binary and a TUI that runs
# on bionic:
#
# 1. The resolver. Bun 1.4.0 bakes process.platform as "android" into a
#    --compile binary and ignores a process.platform define, so @opentui/core's
#    getCurrentNodeAssetTarget() throws "Unsupported OpenTUI Node asset target:
#    android-arm64" and its import switch never matches. Normalise android to
#    linux in the exact places the resolver decides.
#
# 2. The render library. The npm @opentui/core-linux-arm64 libopentui.so is
#    glibc (needs libm.so.6/libc.so.6/libdl.so.2) and cannot dlopen on bionic.
#    Swap in the bionic build vendored in this repo (needs libm.so/libc.so,
#    which Termux provides).
prepare_opentui_android() {
  echo "=== Preparing @opentui/core for bionic (android == linux) ==="

  python3 - "${SCRIPT_DIR}" <<'PY'
import glob, os, sys
root = sys.argv[1]
chunks = glob.glob(os.path.join(root, "opencode", "node_modules", ".bun",
                                "*@opentui+core*", "node_modules", "@opentui",
                                "core", "chunk-bun-*.js"))
# Only the chunk that implements the native-lib resolver needs the
# android==linux normalisation. Other @opentui/core chunks (renderer, workers)
# never select a native asset and behave fine with process.platform="android".
chunks = [c for c in chunks if "getCurrentNodeAssetTarget" in open(c, errors="ignore").read()]
if not chunks:
    print("ERROR: @opentui/core resolver chunk (chunk-bun-*.js) not found in bun store", file=sys.stderr)
    sys.exit(1)
for c in chunks:
    s = open(c).read()
    if "const isLinuxLike = process.platform === \"linux\" || process.platform === \"android\";" in s:
        print(f"resolver already patched: {c}")
        continue
    n = s
    n = n.replace(
        "function getCurrentNodeAssetTarget() {\n  const libc = process.env.OPENTUI_LIBC;",
        "function getCurrentNodeAssetTarget() {\n  const libc = process.env.OPENTUI_LIBC;\n  const isLinuxLike = process.platform === \"linux\" || process.platform === \"android\";",
        1)
    n = n.replace(
        'if (process.platform === "linux" && libc !== undefined',
        'if (isLinuxLike && libc !== undefined', 1)
    n = n.replace(
        "    platform: process.platform,",
        "    platform: isLinuxLike ? \"linux\" : process.platform,", 1)
    n = n.replace(
        '...process.platform === "linux" && libc === "musl"',
        '...isLinuxLike && libc === "musl"', 1)
    n = n.replace(
        '  if (process.platform === "linux") {',
        '  if (process.platform === "linux" || process.platform === "android") {', 1)
    if "process.platform === \"linux\" || process.platform === \"android\"" not in n:
        print(f"ERROR: failed to patch resolver in {c}", file=sys.stderr)
        sys.exit(1)
    open(c, "w").write(n)
    print(f"patched resolver: {c}")
PY

  local pkg
  pkg="$(find "${SCRIPT_DIR}/opencode/node_modules/.bun" -type d \
    -path '*@opentui+core-linux-arm64@*/node_modules/@opentui/core-linux-arm64' 2>/dev/null | head -1)"
  if [ -z "${pkg}" ]; then
    echo "ERROR: @opentui/core-linux-arm64 not found in bun store" >&2
    exit 1
  fi
  cp -f "${SCRIPT_DIR}/vendor/@opentui/core-linux-arm64/libopentui.so" "${pkg}/libopentui.so"
  echo "Replaced ${pkg}/libopentui.so with the bionic build"
}

ensure_bun

cd "${WORKDIR}"

# A full workspace install is mandatory: script/build.ts imports the
# @opencode-ai/script workspace package, and embedding the web UI shells out to
# a vite build in packages/app.
echo "Installing workspace dependencies..."
bun install

prewarm_native_deps
prepare_opentui_android

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
