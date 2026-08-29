# opencode-termux

Pre-built OpenCode binaries for Termux (Android).

## Architectures
- **aarch64** (armv8/aarch64)
- **arm** (armeabi-v7a)
- **amd64** (x86_64)

## Variants
- **pacman** - Uses glibc, includes Bun runtime
- **apt** - Uses bionic libc, no Bun (Bun not available in apt repositories)

## Installation

### Termux (pacman variant - recommended)
```bash
pkg install tur/bun
curl -fsSL https://github.com/<owner>/opencode-termux/releases/latest/download/opencode-linux-aarch64-pacman.tar.gz | tar -xz -C $PREFIX/bin
opencode
```

### Termux (apt variant)
```bash
curl -fsSL https://github.com/<owner>/opencode-termux/releases/latest/download/opencode-linux-aarch64-apt.tar.gz | tar -xz -C $PREFIX/bin
opencode
```

## Building Locally

### Prerequisites
- Docker
- Git

### Build all variants
```bash
docker build -t opencode-termux-build -f Dockerfile.build .
docker run --rm -v $(pwd)/out:/out opencode-termux-build
```

### Build specific variant/arch
```bash
# pacman variant (glibc + Bun)
./build-pacman.sh aarch64 arm64 1.18.25

# apt variant (bionic libc, no Bun)
./build-apt.sh aarch64 arm64 1.18.25
```

## GitHub Actions

The workflow builds on every push to `dev` branch and can be triggered manually with custom versions.

Artifacts are uploaded as release assets.