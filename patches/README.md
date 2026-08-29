# Patches Directory

Patches applied to the opencode source before building.

```
patches/
├── *.patch          # applied first
└── common/*.patch   # applied second
```

There are no variant-specific directories: a single build produces the one
bionic binary that both the apt and pacman variants ship, so there is nothing to
vary.

## These patches are load-bearing

- **`android-target.patch`** — adds the `linux/arm64` bionic target to
  `packages/opencode/script/build.ts`. **Upstream opencode has no android target
  of its own.** Without this patch the build still succeeds, produces all twelve
  other targets, and ships nothing. `build.sh` asserts the android binary exists
  so that failure is loud, and the workflow refuses to run with an empty patch
  set.
- **`install-termux.patch`** — extends the `install` script's Termux handling.

## How to add or refresh a patch

Generate patches with `git diff` against a real checkout:

```bash
cd opencode
# make your edits, then:
git diff -- path/to/file > ../patches/common/my-change.patch
git apply --check ../patches/common/my-change.patch   # verify before committing
```

Hand-written or model-generated diffs tend to have hunk headers whose line counts
do not match their bodies; `git apply` rejects those as `corrupt patch`. Both
patches in this directory were previously in that state and had never once
applied.

## Application is strict

The workflow applies patches with a bare `git apply` and lets failures fail the
build. A patch that no longer applies means upstream moved and the build output
can no longer be trusted — it must not be swallowed with `|| true`.
