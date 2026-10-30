# opencode-termux

Run [opencode](https://github.com/anomalyco/opencode) natively on your Android
phone with [Termux](https://termux.dev).

Upstream opencode only ships glibc and musl builds for Linux, and neither of
those runs on Android. This repo patches opencode's build so it can be
cross-compiled against Android's own libc (bionic), and publishes the result as
a single ready-to-run binary.

> [!NOTE]
> This is an unofficial, community-maintained build. Please report problems
> with the Termux build here, not to the opencode project.

## Installation

There are two ways to get the binary. Both give you the same file:
`opencode-termux-<version>.tar.gz`, which contains a single `opencode`
executable. It works on both stock Termux (`pkg`/`apt`) and termux-pacman,
since they both sit on bionic.

### From a release (recommended)

Grab a tarball from the
[Releases](https://github.com/kaozaza2/opencode-termux/releases) page and
extract it into `$PREFIX/bin`:

```bash
curl -fsSL \
  https://github.com/kaozaza2/opencode-termux/releases/latest/download/opencode-termux-2.1.4.tar.gz \
  | tar -xz -C $PREFIX/bin

opencode
```

Swap `2.1.4` for whichever version you want.

### From a CI build artifact

Every successful run of the
[build workflow](https://github.com/kaozaza2/opencode-termux/actions/workflows/opencode-termux.yml)
uploads the tarball as an artifact named `opencode-tarball`, even when no
release is made. This is the way to try a build from `master` or `dev` before
it's released. Artifacts are kept for 30 days, and you need to be signed in to
GitHub to download them.

The easiest route is the [GitHub CLI](https://cli.github.com), which is
available in Termux:

```bash
pkg install gh
gh auth login

# Download the tarball from the latest successful run on master
RUN_ID=$(gh run list -R kaozaza2/opencode-termux \
  -w opencode-termux.yml -b master -s success -L 1 \
  --json databaseId -q '.[0].databaseId')
gh run download "$RUN_ID" -R kaozaza2/opencode-termux -n opencode-tarball

tar -xzf opencode-termux-*.tar.gz -C $PREFIX/bin
opencode
```

You can also download it from a browser: open a run on the
[Actions](https://github.com/kaozaza2/opencode-termux/actions) tab and click
`opencode-tarball` under **Artifacts**. GitHub delivers it as a `.zip`, so
unzip it first and then extract the tarball inside:

```bash
unzip opencode-tarball.zip
tar -xzf opencode-termux-*.tar.gz -C $PREFIX/bin
```

### Requirements

- An **aarch64** (arm64) device. There's no 32-bit ARM build because Bun has no
  armv7 runtime, and no x86_64 build.
- **Android 11 or newer.** The TUI's native library needs a dynamic linker that
  supports TLS descriptors, which bionic only gained in Android 11. On older
  versions the TUI crashes on startup with `Segmentation fault at address 0x0`.

### Known limitations

- **No browser UI for `opencode serve`.** The web assets add tens of megabytes
  and are left out by default. The server itself runs fine. If you need the UI,
  build with `BUILD_WEB_UI=1`.
- **No file watcher addon.** `@parcel/watcher` has no Android build, so opencode
  falls back to `node:fs` for watching files.
- **PTY support needs an external helper.** `@opencode-ai/pty` has no Android
  build either. opencode will use an `opencode-pty` binary if it finds one on
  your `PATH`.
- **Can't test the TUI in `termux-docker`.** That image ships an old Android
  linker without TLS descriptor support, so the TUI crashes there even though it
  works on a real device. See [vendor/README.md](vendor/README.md#it-needs-a-loader-that-implements-tlsdesc)
  for details.

## Building from source

You don't need an Android device to build. Bun does the cross-compiling, so any
Linux host that Bun supports will do. Node.js 22 or newer is needed for native
postinstall scripts.

```bash
git clone https://github.com/kaozaza2/opencode-termux
cd opencode-termux
./build.sh
```

`build.sh` clones opencode, installs dependencies, applies the patches and
compiles the binary. Then package it with:

```bash
./package.sh   # writes out/opencode-termux-<version>.tar.gz
```

You can also pass a version string to override the one baked into the binary:

```bash
./build.sh 0.0.0-dev-local
```

### With Docker

```bash
docker build -t opencode-termux -f Dockerfile.build .
docker run --rm -v "$(pwd)/out:/workspace/out" opencode-termux
```

### Choosing an opencode version

Set `OPENCODE_REF` to build something other than the pinned default:

```bash
OPENCODE_REF=latest ./build.sh   # newest v2.x.y release tag
OPENCODE_REF=v2.1.4 ./build.sh   # a specific release
OPENCODE_REF=v2 ./build.sh       # tip of the v2 branch
```

Only opencode **v2** is supported. v2 moved the CLI from `packages/opencode` to
`packages/cli` and rewrote the build script, and the patches here target the new
layout. In particular, the upstream `2.0` and `dev` branches are still v1 code,
despite the name, and won't build.

Release tags produce their own version number (`v2.1.4` becomes `2.1.4`).
Branches get a preview version like `0.0.0-dev-<sha>`.

### Configuration

All options are environment variables:

| Variable | Default | Description |
| --- | --- | --- |
| `OPENCODE_REPO` | `https://github.com/anomalyco/opencode.git` | Repository to clone |
| `OPENCODE_REF` | `v2.1.4` | Tag, branch, or `latest` |
| `VERSION` | from the checkout | Version string baked into the binary |
| `BUN_VERSION` | the version opencode pins | Bun used to compile (see below) |
| `BUN_INSTALL_BACKEND` | `hardlink` | Set to `copyfile` if hardlinks misbehave |
| `BUILD_WEB_UI` | `0` | Set to `1` to embed the `opencode serve` web UI |
| `SKIP_CLONE` | unset | Set to `1` to reuse an existing `./opencode` checkout |

A couple of these deserve a closer look.

**`BUN_VERSION`** matters more than it looks. `bun build --compile` embeds the
Bun runtime into the binary, so this is the runtime that actually runs on your
phone. opencode requires a Bun compatible with the version in its
`packageManager` field, and `build.sh` reads that pin from the checkout. You can
still override it within that range, which is handy for bisecting a regression:

```bash
BUN_VERSION=1.4.3 ./build.sh
```

**`BUN_INSTALL_BACKEND`** exists because `bun install` sometimes reports success
but leaves empty package directories behind, particularly on filesystems where
hardlinks are flaky (Android's f2fs, for example). The build later fails with
something confusing like `Could not resolve drizzle-orm`. `build.sh` checks for
this and retries once with `--backend=copyfile` automatically, but you can start
with `copyfile` to skip the problem entirely.

## How it works

Getting opencode onto bionic takes three fixes.

1. **Adding an Android target.** opencode's build script doesn't know about
   Android, so [`android-target.patch`](patches/common/android-target.patch)
   adds a `linux/arm64` bionic entry, compiled with Bun's
   `bun-linux-arm64-android` target. Without this patch, the build silently
   matches no targets, exits successfully, and produces nothing.

2. **Convincing OpenTUI that Android is Linux.** A Bun Android binary reports
   `process.platform` as `"android"`, which `@opentui/core` rejects with
   `Unsupported OpenTUI Node asset target: android-arm64`.
   [`opentui-android.patch`](patches/common/opentui-android.patch) rewrites
   those checks to `"linux"` at bundle time using a `Bun.build` plugin. (A
   simple `define` doesn't work, because Bun inlines the platform itself when
   cross-compiling and its value wins.) The build fails if the plugin finds
   nothing to rewrite, so an OpenTUI update can't quietly ship a broken binary.

3. **Swapping in a bionic `libopentui.so`.** The TUI renderer is a native Zig
   library, and the copy on npm is linked against glibc, so Android can't load
   it. This repo ships its own bionic build in
   [`vendor/`](vendor/README.md) and swaps it in during the build.

There's also [`install-termux.patch`](patches/common/install-termux.patch),
which teaches opencode's `install` script to detect Termux and fetch the
`-android` package. Every patch is described in
[patches/README.md](patches/README.md).

### Target naming

The same target goes by four different names depending on where you look,
which is easy to trip over:

| Where | Name |
| --- | --- |
| `build.ts --target=` | `opencode-linux-arm64-android` |
| Bun compile target | `bun-linux-arm64-android` |
| Output path | `packages/cli/dist/cli-linux-arm64-android/bin/opencode` |
| npm package | `@opencode/cli-linux-arm64-android` |

The scripts here follow upstream's conventions so the release names line up.

## Updating the vendored libopentui

`@opentui/core` changes quickly, and its JavaScript side binds to the native
library by symbol name. A `libopentui.so` built from a different version might
load fine and then crash the first time it hits a function that doesn't exist.
For that reason, the vendored library must match the exact `@opentui/core`
version opencode resolves.

`build.sh` enforces this. It compares
`vendor/@opentui/core-linux-arm64/VERSION` against the checkout and refuses to
build if they differ. When that happens, rebuild the library:

```bash
./scripts/build-libopentui.sh
```

The script checks that the result doesn't link glibc and that it exports every
symbol the JS side expects, using the headers in the checkout itself. See
[vendor/README.md](vendor/README.md) for the full process.

## Continuous integration

The [GitHub Actions workflow](.github/workflows/opencode-termux.yml) builds and
packages the binary on every push to `master` or `dev` that touches the build
files. It can also be started manually, with these inputs:

| Input | Description |
| --- | --- |
| `opencode_ref` | opencode tag or branch (default `latest`) |
| `version` | Override the version string |
| `bun_version` | Override the Bun version |
| `with_web_ui` | Embed the `opencode serve` web UI |
| `release` | Publish a GitHub release with the tarball |

As a sanity check, CI verifies that the output is a real Android ELF (its
program interpreter must be `/system/bin/linker64`), so a mis-targeted build
fails instead of getting released.

## Contributing

Issues and pull requests are welcome. If a new opencode release breaks the
build, the usual suspects are the patches in [`patches/`](patches) and the
vendored `libopentui.so`. Please include the opencode ref and the build log
when reporting a failure.

## Acknowledgements

- [opencode](https://github.com/anomalyco/opencode), the AI coding agent this
  project packages
- [OpenTUI](https://github.com/sst/opentui), the terminal UI library behind it
- [Bun](https://bun.sh), which makes cross-compiling to Android possible
- [Termux](https://termux.dev), for making Android a real Linux environment
