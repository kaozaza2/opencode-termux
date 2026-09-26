#!/usr/bin/env bash
set -euo pipefail

# ./build.sh [version] -- clones opencode, applies patches/, cross-compiles one
# bionic target. Clones the newest v2.x.y release unless OPENCODE_REF says
# otherwise; `2.0` and `dev` are v1 lines, `v2` is the branch head.
#
# Env: OPENCODE_REPO OPENCODE_REF VERSION BUN_VERSION BUN_INSTALL_BACKEND
#      BUILD_WEB_UI=1 SKIP_CLONE=1

VERSION="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${SCRIPT_DIR}/opencode"

OPENCODE_REPO="${OPENCODE_REPO:-https://github.com/anomalyco/opencode.git}"
OPENCODE_REF="${OPENCODE_REF:-latest}"

# One target, four names. The last two differ because build.ts derives the dist
# dir with targetName().replace("opencode","cli") and the installer resolves
# @opencode/cli-<target> from npm.
BUILD_TARGET="opencode-linux-arm64-android"
DIST_NAME="cli-linux-arm64-android"
ANDROID_BINARY="packages/cli/dist/${DIST_NAME}/bin/opencode"

# Only a bionic binary carries this interpreter.
ANDROID_INTERP="/system/bin/linker64"

BUN_INSTALL_BACKEND="${BUN_INSTALL_BACKEND:-hardlink}"

cd "${SCRIPT_DIR}"

latest_release_ref() {
  # sort -V so v2.0.10 outranks v2.0.9; ^{} lines are the same tags again.
  git ls-remote --tags "${OPENCODE_REPO}" 'refs/tags/v2.*' 2>/dev/null |
    awk '{print $2}' |
    sed -e 's#^refs/tags/##' -e 's#\^{}$##' |
    sort -u -V |
    tail -1
}

resolve_ref() {
  if [ "${OPENCODE_REF}" = "latest" ]; then
    OPENCODE_REF="$(latest_release_ref)"
    if [ -z "${OPENCODE_REF}" ]; then
      echo "ERROR: no v2.* tags in ${OPENCODE_REPO}; set OPENCODE_REF=v2." >&2
      exit 1
    fi
  fi
}

# A 0.0.0-dev- prefix is what opencode's Script helper reads as a preview.
derive_version() {
  local tag
  tag="$(git -C "${WORKDIR}" describe --tags --exact-match 2>/dev/null || true)"
  if [ -n "${tag}" ]; then
    printf '%s\n' "${tag#v}"
  else
    printf '0.0.0-dev-%s\n' "$(git -C "${WORKDIR}" rev-parse --short HEAD)"
  fi
}

ensure_source() {
  resolve_ref
  if [ -d "${WORKDIR}/.git" ]; then
    echo "=== Using existing opencode checkout at ${WORKDIR} ==="
  else
    if [ -n "${SKIP_CLONE:-}" ]; then
      echo "ERROR: no opencode checkout at ${WORKDIR} and SKIP_CLONE is set." >&2
      exit 1
    fi
    echo "=== Cloning opencode ${OPENCODE_REF} ==="
    git clone --depth 1 --branch "${OPENCODE_REF}" "${OPENCODE_REPO}" opencode
  fi
  git -C "${WORKDIR}" log --oneline -1
  [ -n "${VERSION}" ] || VERSION="$(derive_version)"
  echo "Building version ${VERSION} from ${OPENCODE_REF}"
  [ -z "${GITHUB_OUTPUT:-}" ] || echo "version=${VERSION}" >> "${GITHUB_OUTPUT}"
}

# Read the pin: @opencode/script enforces ^<packageManager> and it moves.
required_bun_range() {
  bun -e '
    const pin = require("./opencode/package.json").packageManager
    if (!pin?.startsWith("bun@")) { console.error("no bun@ pin"); process.exit(1) }
    const v = pin.slice(4).split(".").map(Number)
    if (!Number.isFinite(v[0]) || !Number.isFinite(v[1])) { console.error("bad pin: " + pin); process.exit(1) }
    console.log(v.join("."))
  '
}

ensure_bun() {
  local want="${BUN_VERSION:-$(required_bun_range)}"
  if command -v bun >/dev/null 2>&1; then
    local have
    have="$(bun --version)"
    echo "Using bun ${have} from $(command -v bun) (checkout requires ^${want})"
    if [ "${have}" != "${want}" ]; then
      # A different patch inside the range is fine; a different major.minor
      # would otherwise fail deep inside @opencode/script.
      if ! bun -e '
          const [h, w] = process.argv.slice(1).map(s => s.split(".").map(Number))
          process.exit(h[0] === w[0] && h[1] === w[1] ? 0 : 1)
        ' "${have}" "${want}" 2>/dev/null; then
        echo "ERROR: bun ${have} does not satisfy ^${want}." >&2
        exit 1
      fi
      echo "NOTE: embedding bun ${have} instead of ${want}." >&2
    fi
    return
  fi

  local os cpu asset url tmp bun_bin
  case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="darwin" ;;
    *) echo "ERROR: unsupported host OS $(uname -s)" >&2; exit 1 ;;
  esac
  # Bun names its aarch64 asset "aarch64"; "arm64" 404s.
  case "$(uname -m)" in
    x86_64 | amd64) cpu="x64" ;;
    aarch64 | arm64) cpu="aarch64" ;;
    *) echo "ERROR: unsupported host arch $(uname -m)" >&2; exit 1 ;;
  esac

  asset="bun-${os}-${cpu}"
  [ "${cpu}" = "x64" ] && asset="${asset}-baseline"
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

CLI_INPUTS=(
  "@opentui/core"
  "@opentui/core/parser.worker"
  "@opentui/solid"
  "@opentui/solid/bun-plugin"
  "@opencode-ai/pty"
  "@parcel/watcher"
  "web-tree-sitter"
  "web-tree-sitter/tree-sitter.wasm"
)

verify_cli_inputs() {
  local missing=0 dep
  for dep in "${CLI_INPUTS[@]}"; do
    if ! (cd "${WORKDIR}/packages/cli" && bun -e "Bun.resolveSync('${dep}', process.cwd())" >/dev/null 2>&1); then
      echo "  unresolved: ${dep}" >&2
      missing=1
    fi
  done
  if [ ! -d "${WORKDIR}/node_modules/@opencode/script" ]; then
    echo "  unresolved: @opencode/script (workspace package)" >&2
    missing=1
  fi
  return "${missing}"
}

# Bun can report success while leaving store entries with a directory skeleton
# and no files, which surfaces much later as `Could not resolve X`. Seen on
# Android's f2fs, where its hardlink backend silently yields empty dirs.
repair_install() {
  echo "=== Repairing a corrupt bun store ===" >&2
  local dir id
  for dir in "${WORKDIR}"/node_modules/.bun/*/node_modules/*/ "${WORKDIR}"/node_modules/.bun/*/node_modules/@*/*/; do
    [ -d "${dir}" ] || continue
    [ "$(basename "${dir}")" = ".bin" ] && continue
    [ -f "${dir}package.json" ] && continue
    # Layout is .bun/<id>/node_modules/<pkg>, so the entry name is two levels up.
    id="$(basename "$(dirname "$(dirname "${dir}")")")"
    echo "  dropping empty store entry: ${id}" >&2
    rm -rf "${dir}" 2>/dev/null || true
  done
  echo "  reinstalling with --backend=copyfile" >&2
  (cd "${WORKDIR}" && bun install --backend=copyfile) >&2 || true
}

install_workspace() {
  echo "=== Installing workspace dependencies ==="
  local backend=()
  [ "${BUN_INSTALL_BACKEND}" != "hardlink" ] && backend=("--backend=${BUN_INSTALL_BACKEND}")
  # A non-zero exit is not automatically fatal (one bad package aborts the whole
  # workspace install), but every input the compile needs must be present.
  (cd "${WORKDIR}" && bun install "${backend[@]+"${backend[@]}"}") || true

  if verify_cli_inputs; then
    echo "All CLI build inputs resolved."
    return
  fi
  repair_install
  if verify_cli_inputs; then
    echo "All CLI build inputs resolved after repair."
    return
  fi
  echo "ERROR: build inputs still missing after a repair attempt." >&2
  echo "       Try: rm -rf opencode/node_modules ~/.bun/install/cache" >&2
  echo "       and re-run, possibly with BUN_INSTALL_BACKEND=copyfile." >&2
  exit 1
}

# The only native deps build.ts installs with --os=* --cpu=*, which is what
# materialises the android @opentui packages. @opencode-ai/pty (v2's
# replacement for @ff-labs/fff-bun) has no android build, which is why
# android-target.patch skips embedding it.
prewarm_native_deps() {
  local core pty
  core="$(bun -e 'console.log(require("./opencode/packages/cli/package.json").dependencies["@opentui/core"])')"
  pty="$(bun -e 'console.log(require("./opencode/packages/cli/package.json").dependencies["@opencode-ai/pty"])')"
  (cd "${WORKDIR}" && bun install --os="*" --cpu="*" "@opentui/core@${core}")
  (cd "${WORKDIR}" && bun install --os="*" --cpu="*" "@opencode-ai/pty@${pty}")
}

apply_patches() {
  echo "=== Applying patches ==="
  local count=0 applied=0 skipped=0 patch
  shopt -s nullglob
  for patch in "${SCRIPT_DIR}"/patches/*.patch "${SCRIPT_DIR}"/patches/common/*.patch; do
    count=$((count + 1))
    if git -C "${WORKDIR}" apply --check "${patch}" 2>/dev/null; then
      echo "  applying $(basename "${patch}")"
      git -C "${WORKDIR}" apply "${patch}"
      applied=$((applied + 1))
    elif git -C "${WORKDIR}" apply --reverse --check "${patch}" 2>/dev/null; then
      echo "  skipping $(basename "${patch}") (already applied)"
      skipped=$((skipped + 1))
    else
      echo "ERROR: $(basename "${patch}") applies neither forward nor reverse." >&2
      echo "       Upstream moved; the build output can no longer be trusted." >&2
      git -C "${WORKDIR}" apply --check "${patch}" 2>&1 | head -5 >&2 || true
      exit 1
    fi
  done
  echo "  applied ${applied}, already present ${skipped}, total ${count}"
  # Load-bearing: with no patches, --target= matches nothing and the build would
  # exit 0 having produced nothing.
  if [ "${count}" -eq 0 ]; then
    echo "ERROR: no patches found; the android target would be missing" >&2
    exit 1
  fi
}

# The npm libopentui.so is a glibc build needing libm.so.6/libc.so.6/libdl.so.2
# and cannot be dlopen()ed on bionic. The vendored one is version-locked to
# @opentui/core, because the JS binds native entry points by symbol name, so a
# blob from another version is missing calls rather than merely outdated -- see
# vendor/README.md.
prepare_opentui_android() {
  echo "=== Swapping @opentui/core-linux-arm64 libopentui.so for bionic ==="
  local pkg vendor want have
  vendor="${SCRIPT_DIR}/vendor/@opentui/core-linux-arm64/libopentui.so"
  if [ ! -f "${vendor}" ]; then
    echo "ERROR: ${vendor} is missing." >&2
    exit 1
  fi
  # A stale blob loads and then fails on first use of a new entry point, which
  # on a phone looks like an unrelated dlopen error. Catch it here instead.
  # v2 pins @opentui/core as "catalog:", so the version lives in the root
  # workspace catalog rather than in the cli package.
  want="$(cd "${WORKDIR}" && bun -e '
    const cli = require("./packages/cli/package.json")
    const root = require("./package.json")
    const dep = cli.dependencies["@opentui/core"]
    const v = dep && dep !== "catalog:" ? dep : root.workspaces?.catalog?.["@opentui/core"]
    if (!v || v === "catalog:") { console.error("cannot resolve @opentui/core"); process.exit(1) }
    console.log(v.replace(/^[\^~>=<\s]+/, ""))
  ')"
  have="$(cat "${SCRIPT_DIR}/vendor/@opentui/core-linux-arm64/VERSION" 2>/dev/null || true)"
  if [ "${have}" != "${want}" ]; then
    echo "ERROR: vendored libopentui.so is for @opentui/core ${have:-unknown}," >&2
    echo "       but this checkout resolves ${want}." >&2
    echo "       Run ./scripts/build-libopentui.sh ${want} and commit the result." >&2
    exit 1
  fi
  pkg="$(find "${WORKDIR}/node_modules/.bun" -type d \
    -path '*@opentui+core-linux-arm64@*/node_modules/@opentui/core-linux-arm64' 2>/dev/null | head -1)"
  if [ -z "${pkg}" ]; then
    echo "ERROR: @opentui/core-linux-arm64 not found in the bun store." >&2
    exit 1
  fi
  cp -f "${vendor}" "${pkg}/libopentui.so"
  echo "  replaced ${pkg}/libopentui.so with the bionic build for @opentui/core ${have}"
}

compile() {
  # No --skip-install: build.ts's own `bun install --os=* --cpu=*` is what
  # materialises the android packages, and prewarm_native_deps already ran the
  # identical commands so they cannot re-extract a glibc .so over the bionic one.
  local args=("--target=${BUILD_TARGET}")
  if [ "${BUILD_WEB_UI:-0}" = "1" ]; then
    echo "Embedding the app assets (BUILD_WEB_UI=1)"
  else
    args+=(--skip-web-ui)
  fi
  echo "=== Compiling ${BUILD_TARGET} ==="
  (cd "${WORKDIR}" && OPENCODE_VERSION="${VERSION}" \
    bun run packages/cli/script/build.ts "${args[@]}")
}

# This repo once shipped a green build that produced nothing, so check the
# output instead of trusting the exit status.
assert_android_binary() {
  if [ ! -f "${WORKDIR}/${ANDROID_BINARY}" ]; then
    echo "ERROR: ${ANDROID_BINARY} was not produced." >&2
    echo "       The android target comes from patches/common/android-target.patch." >&2
    find "${WORKDIR}/packages/cli/dist" -maxdepth 3 >&2 2>/dev/null || true
    exit 1
  fi
  local bin="${WORKDIR}/${ANDROID_BINARY}"
  command -v file >/dev/null 2>&1 && file "${bin}"
  if ! grep -qa -- "${ANDROID_INTERP}" "${bin}"; then
    echo "ERROR: ${bin} is not an android binary (no ${ANDROID_INTERP})." >&2
    exit 1
  fi
  echo "Verified: android binary with ${ANDROID_INTERP} interpreter"
  echo "Android binary: ${bin} ($(wc -c < "${bin}" | tr -d ' ') bytes)"
}

ensure_source
ensure_bun
install_workspace
prewarm_native_deps
apply_patches
prepare_opentui_android
compile
assert_android_binary
