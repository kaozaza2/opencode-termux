#!/usr/bin/env bash
set -euo pipefail

# Regenerates vendor/@opentui/core-linux-arm64/libopentui.so: the bionic build
# of OpenTUI's native Zig core that the Termux binary dlopen()s at startup.
#
#   ./scripts/build-libopentui.sh              # version from the opencode checkout
#   ./scripts/build-libopentui.sh 0.5.12       # explicit @opentui/core version
#
# Requires: git, curl, tar, xz, node, unzip. Zig and the NDK are downloaded.
# Needs ~4 GB of disk for the source, the NDK, Zig and the build cache.
#
# WHY THIS NEEDS A NDK AND A ZIG PATCH
#
#   Zig bundles only glibc and musl, so for aarch64-linux-android it reports
#   "unable to provide libc" and offers no related target. The libc is supplied
#   by hand instead:
#
#     ZIG_LIBC             a libc config naming the include and crt dirs
#     BIONIC_SYSROOT_INC   NDK usr/include with the arch dir flattened in, plus
#                          __opentui/ shim headers that expand _Nullable and
#                          _Nonnull to nothing, which translate-c rejects when
#                          they appear on array parameters
#
#   Zig's own std also needs a sigaction fix, because bionic's sigset_t is 8
#   bytes where Zig's linux one is 128, so the libc wrapper cannot be used.
#
#   The opentui build.zig patch then points the two b.addTranslateC steps at the
#   merged include dir, which is the only way their -I reaches translate-c:
#   module include_dirs do not.
#
# WHY THE .SO IS VERSION-LOCKED
#
#   The npm @opentui/core-linux-arm64 libopentui.so is a glibc build. It needs
#   libm.so.6 / libc.so.6 / libdl.so.2, none of which exist on Android, so it
#   cannot be dlopen()ed from a Termux process. Hence the vendored bionic build.
#
#   But the vendored blob is only valid for the exact @opentui/core version it
#   was compiled from. The JS half resolves native entry points by name
#   (createRenderer, imageCreateFromPixels, processKittyImageReply, ...), so a
#   .so missing any of them either fails to load or calls into a symbol that
#   does not exist. opencode v2 uses @opentui/core 0.5.12, whose Zig core
#   exports 7 entry points the previously vendored blob did not have:
#
#     imageCreateFromPixels  imageUpdatePixels
#     processKittyImageReply cancelKittyImageTransport
#     getKittyImageTransport pollKittyImageTransport
#     setKittyImageTransport
#
#   So bump @opentui/core and this blob goes stale. build.sh will happily copy a
#   stale .so into the binary and the failure only shows up as a dlopen error on
#   the phone, so the checks at the bottom of this script matter.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${OPENTUI_BUILD_DIR:-${TMPDIR:-/tmp}/opentui-native-build}"

# build.zig refuses to run unless this is the exact Zig version it pins.
ZIG_VERSION="0.16.0"
# The only bionic target opencode builds for. Matches the android entry that
# android-target.patch adds to build.ts's allTargets.
ZIG_TARGET="aarch64-linux-android"
# API level whose crt objects and stubs are linked against. 29 is what the
# Termux packages target and what the previous vendored blob was built for.
ANDROID_API="${ANDROID_API:-29}"
NDK_VERSION="${NDK_VERSION:-r27c}"
NDK_URL="https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip"
OPENTUI_REPO="https://github.com/anomalyco/opentui.git"

VERSION="${1:-}"
if [ -z "${VERSION}" ]; then
  # Read the version opencode actually resolves, so the blob can never drift
  # from the JS that loads it.
  PKG="${REPO_DIR}/opencode/packages/cli/package.json"
  if [ ! -f "${PKG}" ]; then
    echo "ERROR: pass the @opentui/core version explicitly, e.g. $0 0.5.12" >&2
    echo "       (no opencode checkout at ${PKG} to read it from)" >&2
    exit 1
  fi
  VERSION="$(node -e '
    const root = require(process.argv[1] + "/package.json")
    const cat = root.workspaces?.catalog?.["@opentui/core"]
    const dep = require(process.argv[2]).dependencies["@opentui/core"]
    const v = dep && dep !== "catalog:" ? dep : cat
    if (!v || v === "catalog:") { console.error("could not resolve @opentui/core"); process.exit(1) }
    console.log(v.replace(/^[\^~>=<\s]+/, ""))
  ' "${REPO_DIR}/opencode" "${PKG}")"
fi

echo "=== Rebuilding bionic libopentui.so for @opentui/core ${VERSION} ==="
mkdir -p "${WORK}"
SRC="${WORK}/opentui-${VERSION}"

# ------------------------------------------------------------------ opentui src
if [ ! -d "${SRC}/.git" ]; then
  echo "--- cloning opentui v${VERSION}"
  rm -rf "${SRC}"
  git clone --depth 1 --branch "v${VERSION}" "${OPENTUI_REPO}" "${SRC}"
else
  echo "--- reusing ${SRC}"
fi

# Paths a patch file touches, as git would name them.
patch_paths() {
  awk '/^diff --git /{print $4}' "$1" | sed 's|^b/||'
}

# Guard against a dirty tree: a half-applied edit would produce a .so that does
# not match the published JS. Modifications to the files this script patches are
# expected on a re-run, so only flag anything else.
unexpected_edits() {
  local root="$1" allowed line path p
  shift
  allowed="$(for p in "$@"; do patch_paths "${p}"; done | sort -u)"
  while IFS= read -r line; do
    case "${line:0:2}" in
      " M" | "M " | "MM" | "AM") ;;
      *) continue ;;
    esac
    path="${line:3}"
    if ! printf '%s\n' "${allowed}" | grep -qxF "${path}"; then
      printf '%s\n' "${path}"
    fi
  done < <(git -C "${root}" status --porcelain 2>/dev/null)
}

OPENTUI_PATCH="${REPO_DIR}/patches/opentui/android-libopentui.patch"
if [ ! -f "${OPENTUI_PATCH}" ]; then
  echo "ERROR: missing ${OPENTUI_PATCH}" >&2
  exit 1
fi
edits="$(unexpected_edits "${SRC}" "${OPENTUI_PATCH}")"
if [ -n "${edits}" ]; then
  echo "ERROR: ${SRC} has local modifications; refusing to build:" >&2
  printf '  %s\n' ${edits} >&2
  exit 1
fi

resolved="$(node -e "console.log(require('${SRC}/packages/core/package.json').version)")"
if [ "${resolved}" != "${VERSION}" ]; then
  echo "ERROR: checked out @opentui/core ${resolved} but expected ${VERSION}" >&2
  exit 1
fi

# ----------------------------------------------------------------------- zig
ZIG_DIR="${WORK}/zig-${ZIG_VERSION}"
if [ ! -x "${ZIG_DIR}/zig" ]; then
  echo "--- fetching zig ${ZIG_VERSION}"
  case "$(uname -m)" in
    x86_64 | amd64) ZIG_ARCH="x86_64" ;;
    aarch64 | arm64) ZIG_ARCH="aarch64" ;;
    *) echo "ERROR: unsupported host arch $(uname -m)" >&2; exit 1 ;;
  esac
  ARCHIVE="zig-${ZIG_ARCH}-linux-${ZIG_VERSION}"
  (cd "${WORK}" &&
    curl -fsSL -o "${ARCHIVE}.tar.xz" \
      "https://ziglang.org/download/${ZIG_VERSION}/${ARCHIVE}.tar.xz" &&
    tar xJf "${ARCHIVE}.tar.xz" &&
    rm -f "${ARCHIVE}.tar.xz")
  mv "${WORK}/${ARCHIVE}" "${ZIG_DIR}"
fi

export PATH="${ZIG_DIR}:${PATH}"
echo "--- zig $(zig version)"

# ----------------------------------------------------------------------- ndk
# Only the sysroot headers and libs are extracted; the rest of the NDK is
# toolchain binaries this build never runs.
NDK_HOME="${WORK}/android-ndk-${NDK_VERSION}"
NDK_SYSROOT="${NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
if [ ! -d "${NDK_SYSROOT}/usr/include" ]; then
  echo "--- fetching android ndk ${NDK_VERSION}"
  (cd "${WORK}" && curl -fsSL -o ndk.zip "${NDK_URL}")
  rm -rf "${NDK_HOME}"
  (cd "${WORK}" && unzip -q -o ndk.zip \
    "android-ndk-${NDK_VERSION}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/*" \
    "android-ndk-${NDK_VERSION}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/*")
  rm -f "${WORK}/ndk.zip"
fi

CRT_DIR="${NDK_SYSROOT}/usr/lib/aarch64-linux-android/${ANDROID_API}"
if [ ! -f "${CRT_DIR}/crtbegin_so.o" ] || [ ! -f "${CRT_DIR}/libc.so" ]; then
  echo "ERROR: NDK sysroot incomplete: ${CRT_DIR} is missing crtbegin_so.o or libc.so" >&2
  exit 1
fi

# ------------------------------------------------- merged bionic include tree
# Zig resolves one include dir, but the NDK splits headers across
# usr/include and usr/include/<triple>. Merge them, then add shim headers that
# expand the nullability macros to nothing before including the real header:
# translate-c rejects _Nullable on an array parameter outright, and the NDK
# applies it to utimes/futimes/utimensat and friends.
INC="${WORK}/bionic-include"
echo "--- preparing merged bionic include tree"
rm -rf "${INC}"
mkdir -p "${INC}/__opentui"
cp -a "${NDK_SYSROOT}/usr/include/." "${INC}/"
cp -a "${NDK_SYSROOT}/usr/include/aarch64-linux-android/." "${INC}/"

# The shims sit outside the source tree, so they include by absolute path.
printf '#define _Nullable\n#define _Nonnull\n#include "%s/src/vendor/miniaudio/miniaudio.h"\n' \
  "${SRC}/packages/native" >"${INC}/__opentui/miniaudio_shimmed.h"
printf '#define _Nullable\n#define _Nonnull\n#include "%s/zig-deps/yoga/yoga/Yoga.h"\n' \
  "${SRC}/packages/native" >"${INC}/__opentui/Yoga_shimmed.h"

# The libc config Zig reads for a target it cannot provide itself.
cat >"${WORK}/bionic-libc.txt" <<EOF
include_dir=${INC}
sys_include_dir=${INC}
crt_dir=${CRT_DIR}
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
EOF

# --------------------------------------------------------------------- patches
apply_patch() {
  local file="$1" root="$2"
  if git -C "${root}" apply --reverse --check "${file}" 2>/dev/null; then
    echo "--- already applied: $(basename "${file}")"
    return 0
  fi
  if git -C "${root}" apply --check "${file}" 2>/dev/null; then
    git -C "${root}" apply "${file}"
    echo "--- applied: $(basename "${file}")"
    return 0
  fi
  echo "ERROR: $(basename "${file}") does not apply to ${root}" >&2
  git -C "${root}" apply --check "${file}" 2>&1 | head -20 >&2 || true
  exit 1
}

apply_patch "${REPO_DIR}/patches/zig/posix-android-sigaction.patch" "${ZIG_DIR}"

# Zig's build cache creates files with O_TMPFILE and then hardlinks them into
# place, and linkat(AT_EMPTY_PATH) needs CAP_DAC_READ_SEARCH. Sandboxes and
# proot drop that capability and Zig aborts, so fall back to a named temp file
# plus rename() where the capability is missing.
if [ -r /proc/self/status ]; then
  capeff="$(awk '/^CapEff:/ {print $2}' /proc/self/status)"
  if [ -n "${capeff}" ] && [ "$(( 0x${capeff} & 0x4 ))" -eq 0 ]; then
    apply_patch "${REPO_DIR}/patches/zig/cache-no-tmpfile.patch" "${ZIG_DIR}"
  fi
fi

# --------------------------------------------------------------------- build
cd "${SRC}/packages/native"

apply_patch "${OPENTUI_PATCH}" "${SRC}"

# The Zig dependencies (yoga, ghostty/uucode VT) ship as a vendored tarball in
# the repo, so this needs no network.
if [ ! -f zig-deps/.ready ]; then
  echo "--- preparing zig dependencies"
  sh scripts/prepare-zig-deps.sh
fi

export ANDROID_NDK_HOME="${NDK_HOME}"
export BIONIC_SYSROOT_INC="${INC}"
export ZIG_LIBC="${WORK}/bionic-libc.txt"

echo "--- zig build -Doptimize=ReleaseFast -Dlibrary-target=${ZIG_TARGET}"
zig build -Doptimize=ReleaseFast -Dlibrary-target="${ZIG_TARGET}"

BUILT="${SRC}/packages/native/lib/${ZIG_TARGET}/libopentui.so"
if [ ! -f "${BUILT}" ]; then
  BUILT="$(find "${SRC}/packages/native/lib" -name libopentui.so 2>/dev/null | head -1)"
fi
if [ -z "${BUILT}" ] || [ ! -f "${BUILT}" ]; then
  echo "ERROR: zig build produced no libopentui.so" >&2
  exit 1
fi
echo "--- built ${BUILT}"

# -------------------------------------------------------------------- verify
# A bionic object links libc.so/libm.so/libdl.so; a glibc one links
# libc.so.6/libm.so.6. If the android target ever silently produced a glibc
# object, catch it here instead of on the phone.
if command -v readelf >/dev/null 2>&1; then
  NEEDED="$(readelf -d "${BUILT}" | grep NEEDED || true)"
  echo "--- NEEDED: $(echo "${NEEDED}" | tr -s ' ' | tr '\n' ' ')"
  if echo "${NEEDED}" | grep -qE "libc\.so\.6|libm\.so\.6|libdl\.so\.2"; then
    echo "ERROR: built .so links glibc; expected bionic" >&2
    exit 1
  fi
elif grep -qa "libc\.so\.6" "${BUILT}"; then
  echo "ERROR: built .so links glibc; expected bionic" >&2
  exit 1
else
  echo "--- readelf unavailable, relying on the glibc soname probe"
fi

# The JS binds natives by symbol name, so a .so missing an entry point dlopens
# fine and then fails at first call. Check the ones this version is known to
# have added, so a stale blob cannot be committed by accident.
missing=""
for sym in createRenderer processKittyImageReply imageCreateFromPixels \
  imageUpdatePixels cancelKittyImageTransport getKittyImageTransport \
  pollKittyImageTransport setKittyImageTransport; do
  if ! grep -qa "${sym}" "${BUILT}"; then
    missing="${missing} ${sym}"
  fi
done
if [ -n "${missing}" ]; then
  echo "ERROR: built .so is missing expected exports:${missing}" >&2
  exit 1
fi
echo "--- exports verified"

# ------------------------------------------------------------------- install
DEST="${REPO_DIR}/vendor/@opentui/core-linux-arm64/libopentui.so"
mkdir -p "$(dirname "${DEST}")"
# opentui's buildTarget sets .strip = false so the release symbols describe the
# exact optimized code, and leaves stripping to whoever packages it. Stripping
# drops .symtab but keeps .dynsym, which is what the JS binds against.
# binutils is absent on some hosts (Termux); zig's objcopy cannot strip ELF.
if command -v strip >/dev/null 2>&1; then
  strip --strip-unneeded -o "${DEST}" "${BUILT}"
else
  echo "--- WARNING: no strip(1); installing unstripped (~$(du -h "${BUILT}" | cut -f1) with debug_info)" >&2
  cp -f "${BUILT}" "${DEST}"
fi
chmod +x "${DEST}"
# build.sh compares this against the version the checkout resolves, so a blob
# cannot go stale unnoticed.
printf '%s\n' "${VERSION}" >"$(dirname "${DEST}")/VERSION"

echo
echo "=== Installed ${DEST} (@opentui/core ${VERSION}) ==="
ls -la "${DEST}"
# Re-check after stripping: --strip-unneeded must not have taken .dynsym with it.
missing=""
for sym in createRenderer processKittyImageReply; do
  grep -qa "${sym}" "${DEST}" || missing="${missing} ${sym}"
done
if [ -n "${missing}" ]; then
  echo "ERROR: installed .so lost exports during stripping:${missing}" >&2
  exit 1
fi
echo
echo "Rebuild the Termux binary so build.sh copies this into the bun store:"
echo "    ./build.sh"
