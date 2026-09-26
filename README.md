# opencode-termux

Pre-built [opencode](https://github.com/anomalyco/opencode) binaries for Termux
(Android), cross-compiled against **bionic** libc.

## What you get

One tarball, `opencode-termux-<version>.tar.gz`, containing a single aarch64
binary. Stock Termux (`apt`/`pkg`) and termux-pacman both run on bionic, so the
same file works on both — there is no per-package-manager build.

```bash
curl -fsSL \
  https://github.com/kaozaza2/opencode-termux/releases/latest/download/opencode-termux-2.0.18.tar.gz \
  | tar -xz -C $PREFIX/bin
opencode
```

No 32-bit ARM build (Bun ships no armv7 runtime) and no x86_64 build (the
patched target list has exactly one bionic entry, `linux/arm64`).

## Upstream ref

These builds track **opencode v2**, which moved the binary package from
`packages/opencode` to `packages/cli` and rewrote its build script. The patches
here target `packages/cli/script/build.ts` and do not apply to v1.

| Ref | What it is |
| --- | --- |
| `latest` | the highest published `v2.x.y` tag — **the default** |
| `v2.0.18` | one specific release, fixed |
| `v2` | the v2 branch head, moves |
| `2.0` | **not v2** — a stale exploration branch still on `packages/opencode` 1.x |
| `dev` | v1 |

A tag is the default so rebuilding a version reproduces the same binary. The
version comes from whatever was checked out: the tag for a tag (`v2.0.18` →
`2.0.18`), and a `0.0.0-dev-<sha>` preview for a moving branch, which is the
prefix opencode's own `Script` helper reads as a preview.

## Building

```bash
./build.sh                 # newest v2 release
./build.sh 0.0.0-dev-local # override the version string
```

`build.sh` does the whole job: it clones, installs, applies the patches and
cross-compiles. Nothing arm64 executes, so the host can be anything Bun
cross-compiles from.

In Docker:

```bash
docker build -t opencode-termux -f Dockerfile.build .
docker run --rm -v "$(pwd)/out:/workspace/out" opencode-termux
```

Or with an explicit ref: `OPENCODE_REF=v2 ./build.sh`.

### Environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `OPENCODE_REPO` | `github.com/anomalyco/opencode` | source repo |
| `OPENCODE_REF` | `latest` | tag, branch, or `latest` |
| `VERSION` | derived from the checkout | version string baked in |
| `BUN_VERSION` | the version the checkout pins | see [Bun](#the-bun-version-is-a-runtime-choice) |
| `BUN_INSTALL_BACKEND` | `hardlink` | set `copyfile` to avoid hardlinks |
| `BUILD_WEB_UI` | `0` | `1` embeds the app assets |
| `SKIP_CLONE` | unset | `1` requires an existing `./opencode` |

## How it works

### One target, four names

This is the part that is easy to get wrong, because the same target is spelled
four different ways:

| Role | Name |
| --- | --- |
| build target (`--target=`) | `opencode-linux-arm64-android` |
| Bun compile target | `bun-linux-arm64-android` |
| dist directory | `packages/cli/dist/cli-linux-arm64-android/bin/opencode` |
| npm package | `@opencode/cli-linux-arm64-android` |

The last two differ from the first two because `build.ts` derives the dist
directory with `targetName(item).replace("opencode", "cli")`, and the `install`
script resolves `@opencode/cli-<target>` from npm. `build.sh` and `package.sh`
both reproduce the spellings so the release names line up with upstream.

`--target=` only exists in v2. Under v1 the build script had no target filter,
so every run compiled the full twelve-target matrix and threw eleven of them
away; that is why CI is now roughly a third of its old cost.

### Three bionic gaps

1. **The resolver.** A Bun android binary reports `process.platform` as
   `"android"`, but `@opentui/core` accepts only `linux`/`darwin`/`win32` and
   throws `Unsupported OpenTUI Node asset target: android-arm64`.
   `patches/common/opentui-android.patch` pins the value to `"linux"` at bundle
   time, which reaches the pre-bundled chunks without rewriting files in the bun
   store.

2. **The render library.** The npm `libopentui.so` is a glibc build needing
   `libm.so.6` / `libc.so.6` / `libdl.so.2` and cannot be `dlopen()`ed on bionic,
   so `build.sh` swaps in a bionic build from `vendor/`. See
   [Known limitation](#known-limitation).

3. **The other addons.** `@opencode-ai/pty` (v2's replacement for
   `@ff-labs/fff-bun`) and `@parcel/watcher` publish only glibc/musl builds.
   `android-target.patch` leaves both unset, so the runtime falls back to an
   `opencode-pty` on `PATH` and to `node:fs` respectively.

`patches/README.md` documents each patch, and `patches/common/android-target.patch`
is load-bearing: without it `--target=` matches nothing and the build exits 0
having produced nothing.

### The Bun version is a runtime choice

`bun build --compile` embeds the compiling Bun's runtime into the binary, so it
decides what actually runs on your phone.

It is not a free choice: `@opencode/script` reads the checkout's
`packageManager` field and throws unless the running Bun satisfies
`^<that version>`. `build.sh` reads the pin from the checkout rather than
hardcoding it, so it cannot drift as upstream moves. Override within the range
to bisect a regression:

```bash
BUN_VERSION=1.4.3 ./build.sh
```

### The app assets are skipped by default

The embedded app assets are a brotli bundle of the vite build of `packages/app`,
cost tens of MB, and are only used by `opencode serve`'s browser UI. They are
off by default, so `opencode serve` still runs but its browser UI will not load.
Enable with `BUILD_WEB_UI=1 ./build.sh`.

### It heals a broken install

`bun install` can report success while leaving store entries with a directory
skeleton and no files. The symptom shows up much later as
`Could not resolve drizzle-orm`, from a build that has already moved on. It
happens where Bun's default hardlink backend is unreliable — Android's f2fs
among them.

So `build.sh` checks that everything the compile imports actually resolves, and
on failure drops the empty store entries and reinstalls once with
`--backend=copyfile`. If that does not help it fails loudly rather than handing
an opaque bundler error to the next step. To skip hardlinks from the start:

```bash
BUN_INSTALL_BACKEND=copyfile ./build.sh
```

## The vendored native library

`vendor/@opentui/core-linux-arm64/libopentui.so` is a bionic build of OpenTUI's
Zig core, compiled from the exact `@opentui/core` version opencode resolves.
That coupling is forced, not incidental:

- The npm `@opentui/core-linux-arm64` `.so` is a glibc build needing
  `libm.so.6`/`libc.so.6`/`libdl.so.2`, so it cannot be `dlopen()`ed on Android.
- The JS half binds native entry points **by symbol name**, so a `.so` built
  from a different `@opentui/core` is *missing calls* rather than merely out of
  date — it can load fine and then crash on first use of a new entry point.

opencode v2 resolves `@opentui/core` 0.5.12, which added seven entry points the
previously committed blob did not export:

```
imageCreateFromPixels   imageUpdatePixels
processKittyImageReply  cancelKittyImageTransport
getKittyImageTransport  pollKittyImageTransport
setKittyImageTransport
```

So **when `@opentui/core` is bumped, rebuild the blob** with
`./scripts/build-libopentui.sh` (see `vendor/README.md`). It refuses to install
a `.so` that links glibc or that is missing those exports, so a stale blob
cannot be committed by accident. `build.sh` additionally compares
`vendor/@opentui/core-linux-arm64/VERSION` against the version the checkout
resolves and refuses to build on a mismatch, so the failure cannot reach a
phone.

## GitHub Actions

`.github/workflows/opencode-termux.yml` builds once and packages the single
tarball. It runs on push to `master`/`dev` when the build files change, or
manually via `workflow_dispatch`.

`build.sh` writes the version it resolved to `$GITHUB_OUTPUT`, so the packaging
and release jobs cannot drift from the binary that was actually built. The build
also asserts its output is an Android ELF by looking for the
`/system/bin/linker64` program interpreter, so a mis-targeted build fails
instead of shipping.

Inputs: `opencode_ref` (default `latest`), `version`, `bun_version`,
`with_web_ui`, `release`.
