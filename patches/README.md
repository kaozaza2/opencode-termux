# Patches Directory

This directory contains patches that are applied to the opencode source before building.

## Structure

```
patches/
├── common/          # Applied to both pacman and apt variants
│   ├── android-target.patch    # Adds Android/bionic target to build script
│   └── install-termux.patch    # Adds Termux detection to install script
├── pacman/          # Applied only to pacman variant (glibc + Bun)
└── apt/             # Applied only to apt variant (bionic libc)
```

## How to Add Patches

1. Make changes to the opencode source locally
2. Generate a patch:
   ```bash
   cd opencode
   git diff > ../patches/common/my-change.patch
   ```
3. Or for variant-specific patches:
   ```bash
   git diff > ../patches/pacman/my-change.patch
   git diff > ../patches/apt/my-change.patch
   ```

## Patch Application Order

1. Common patches (applied first)
2. Variant-specific patches (pacman or apt)

Patches are applied with `git apply` and failures are ignored (using `|| true`) to allow optional patches.