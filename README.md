# opencode-termux

Pre-built [opencode](https://github.com/anomalyco/opencode) binaries for Termux (Android).

## What gets built

A single binary: `opencode-linux-arm64-android`, compiled against **bionic** libc.

Both Termux package managers run on bionic, so stock Termux (`apt`/`pkg`) and
termux-pacman install the same binary — only the tarball name differs.

| Arch | Variant | Tarball |
| --- | --- | --- |
| aarch64 | apt | `opencode-<version>-aarch64-apt.tar.gz` |
| aarch64 | pacman | `opencode-<version>-aarch64-pacman.tar.gz` |

There is no 32-bit ARM build — Bun ships no armv7 binary — and no x86_64 build,
because opencode's target list has exactly one bionic entry (`linux/arm64`).

## Installation

```bash
curl -fsSL https://github.com/kaozaza2/opencode-termux/releases/latest/download/opencode-aarch64-apt.tar.gz \
  | tar -xz -C $PREFIX/bin
opencode
```

Swap `apt` for `pacman` if you are on termux-pacman; the payload is identical.

## Building

`build.sh` cross-compiles from an x86_64 host — nothing arm64 executes during
the build. This is the same invocation opencode's own `publish.yml` releases
with, so it stays on a supported path.

```bash
git clone --depth 1 --branch dev https://github.com/anomalyco/opencode.git opencode
./build.sh 0.0.0-dev-local
./package.sh aarch64 apt 0.0.0-dev-local
```

Or in Docker, which handles the clone and both variants:

```bash
docker build -t opencode-termux -f Dockerfile.build .
docker run --rm -v "$(pwd)/out:/workspace/out" opencode-termux
```

### Why the build looks wasteful

`packages/opencode/script/build.ts` takes no target filter — its target list is
hardcoded, and `--single` restricts it to the *host* platform, which would never
emit an arm64 binary. So every target is compiled and all but the android one is
discarded. Narrowing it would mean carrying a patch against a moving upstream
branch; the redundant compiles are the cheaper trade.

### The web UI is skipped by default

The embedded web UI (a vite build of `packages/app`) costs tens of MB and only
`opencode serve`'s browser UI needs it, so it is **not** embedded by default —
this is the main reason the shipped binary stays around 150 MB instead of
175–185 MB. `opencode serve` still works; its browser UI just won't load.

Embed it back in with `BUILD_WEB_UI=1 ./build.sh <version>` (or the legacy
`SKIP_WEB_UI=0`), and the workflow exposes the same choice as the
`with_web_ui` workflow_dispatch input.

### The Bun version is a runtime choice

`bun build --compile` embeds the compiling Bun's runtime into the binary, so
`BUN_VERSION` in `build.sh` decides what actually runs on your phone.

It is pinned to **1.4.0**, deliberately *not* to opencode's `packageManager`
field (1.3.14). A 1.3.14-compiled binary segfaults at startup on arm64 bionic,
inside the JS parser lowering `using` declarations
(`js_parser ... LowerUsingDeclarationsContext.finalize`, reported as
`pre-init`), while the same device runs Bun 1.4.0 fine.

`script/build.ts` independently enforces a `^<packageManager>` range and fails
with a clear message if the pin ever drifts outside it.

```bash
BUN_VERSION=1.4.1 ./build.sh <version>   # bisect a Bun regression
```

The workflow exposes the same knob as a `bun_version` workflow_dispatch input.

## GitHub Actions

`.github/workflows/opencode-termux.yml` builds once, then packages both variants
from that single binary. It runs on push to `master`/`dev` when the build files
change, or manually via workflow_dispatch — which also takes a `release` input
to publish the tarballs as a GitHub release.
