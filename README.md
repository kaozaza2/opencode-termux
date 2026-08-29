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

`SKIP_WEB_UI=1 ./build.sh <version>` drops the embedded web UI (a vite build of
`packages/app`) if you need a faster or more reliable build, at the cost of
`opencode serve`'s browser UI.

## GitHub Actions

`.github/workflows/opencode-termux.yml` builds once, then packages both variants
from that single binary. It runs on push to `master`/`dev` when the build files
change, or manually via workflow_dispatch — which also takes a `release` input
to publish the tarballs as a GitHub release.
