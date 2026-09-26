# Patches Directory

Patches applied to the opencode source before building.

```
patches/
├── common/*.patch         # opencode, applied by build.sh
├── opentui/*.patch        # opentui, applied by scripts/build-libopentui.sh
└── zig/*.patch            # the zig toolchain, likewise
```

There are no variant-specific directories: a single build produces the one
bionic binary that both Termux package managers install, so there is nothing to
vary.

`common/` patches the opencode checkout. `opentui/` and `zig/` are used only when
regenerating `vendor/@opentui/core-linux-arm64/libopentui.so`, which is its own
build with its own toolchain; see `vendor/README.md`.

## All three common patches target opencode v2

v2 relocated the binary package from `packages/opencode` to `packages/cli` and
rewrote the build script, so these patches no longer apply to a v1 checkout.
The v1 forms touched `packages/opencode/script/build.ts`; these touch
`packages/cli/script/build.ts`. Verified against `v2.0.16`.

## These patches are load-bearing

### `android-target.patch` — `packages/cli/script/build.ts`

**Upstream opencode has no android target of its own**, and without this patch
`--target=opencode-linux-arm64-android` matches nothing in `allTargets` and
nothing is produced. Adds:

- `android?: boolean` on the `allTargets` entry type, and one new entry,
  `{ os: "linux", arch: "arm64", android: true }`.
- an `-android` suffix in `targetName()`, so the target is
  `opencode-linux-arm64-android`. That single function drives three things:
  the `--target=` filter, the bun compile target (`bun-linux-arm64-android`),
  and the dist directory (`cli-linux-arm64-android`, because build.ts does
  `targetName(item).replace("opencode", "cli")`).
- two glibc-only native addons disabled for android:
  - `resolveOpencodePty()` is skipped. `@opencode-ai/pty` (which replaced
    `@ff-labs/fff-bun` in v2) publishes only glibc/musl builds, and exec'ing one
    on bionic fails. Skipping it makes the core fall back to `opencode-pty` on
    `PATH` — see `binary.bun.ts`, whose `resolveBinary` returns the bare name
    when the embedded asset is `undefined`.
  - the `@parcel/watcher` binding resolves to `undefined`, so
    `core/src/filesystem/watcher.ts` takes its `node:fs` path. It already wraps
    the native load in `try/catch`, but skipping the `require` outright avoids
    dlopen()ing a glibc addon at all.

### `opentui-android.patch` — `packages/cli/script/build.ts`

Pins `process.platform` to `"linux"` in the bundle for android targets only. A
bun android binary reports `process.platform === "android"`, and
`@opentui/core`'s `getCurrentNodeAssetTarget()` feeds that straight into
`getNativeAssetDescriptor()`, which accepts only `linux`/`darwin`/`win32` and
otherwise throws `Unsupported OpenTUI Node asset target: android-arm64`. Doing
it through bun's `define` means the substitution happens at bundle time, so it
reaches the pre-bundled `chunk-bun-*.js` without rewriting files in the bun
store. Still required in 0.5.10 — the resolver is unchanged from 0.4.5.

### `install-termux.patch` — `install`

Detects Termux and appends `-android` to the npm target, so the installer
resolves `@opencode/cli-linux-arm64-android`. Also suppresses the musl probe,
which is meaningless on bionic.

## The other half is not a patch

`vendor/@opentui/core-linux-arm64/libopentui.so` is a bionic build of OpenTUI's
Zig core. It cannot be a patch because it is a compiled binary, and it has to be
regenerated whenever `@opentui/core` is bumped — the JS binds native entry
points by symbol name, so a `.so` from a different version is missing calls
rather than merely outdated. See `scripts/build-libopentui.sh` and
`vendor/README.md`.

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
applied. A patch that drops comment-only lines must have its hunk header
re-counted by hand, since removing added lines changes the new-side count.

Patches that edit the same file in sequence need their hunk offsets generated
from the intermediate state, not from the pristine checkout. To split one file's
changes across two patches, commit the first half, apply the second, and
`git diff` only the second.

## Application is strict

The workflow applies patches with a bare `git apply` and lets failures fail the
build. A patch that no longer applies means upstream moved and the build output
can no longer be trusted — it must not be swallowed with `|| true`.
