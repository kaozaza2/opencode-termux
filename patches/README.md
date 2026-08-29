# Patches Directory

Patches applied to the opencode source before building.

```
patches/
├── *.patch          # applied first
└── common/*.patch   # applied second
```

There are no variant-specific directories: a single build produces the one
bionic binary that both the apt and pacman variants ship, so there is nothing to
vary. The directory is currently empty — see below.

## How to add a patch

```bash
cd opencode
git diff > ../patches/common/my-change.patch
```

Generate patches with `git diff` against the actual source. Hand-written or
model-generated diffs tend to have hunk headers whose line counts do not match
their bodies, which `git apply` rejects as `corrupt patch`.

## Application is strict

The workflow applies patches with a bare `git apply` and lets failures fail the
build. A patch that no longer applies is a signal that upstream moved, not
something to swallow — silently ignoring failures is how this repo ended up
shipping two patches that had never once applied.

## Removed patches

Both previous patches were deleted after being found redundant *and* corrupt:

- `android-target.patch` — added the `linux/arm64` android target to
  `script/build.ts`. Upstream `dev` already has the target entry, the
  `compileTarget` android branch, the `!item.android` smoke-test guard, and
  `libc: ["bionic"]`.
- `install-termux.patch` — added `--binary` and Termux detection to the `install`
  script. Upstream `dev` already has the `-b, --binary` flag, `binary_path`
  handling, `install_from_binary`, and `is_termux` detection via
  `TERMUX_VERSION`, `/data/data/com.termux`, and `uname -o`.
