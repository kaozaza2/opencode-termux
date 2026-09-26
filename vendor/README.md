# vendor/

## @opentui/core-linux-arm64/libopentui.so

A **bionic** build of OpenTUI's native Zig core.

The npm package `@opentui/core-linux-arm64` ships a glibc build, which needs
`libm.so.6`, `libc.so.6` and `libdl.so.2`. None of those exist on Android, so
the shipped `.so` cannot be `dlopen()`ed from a Termux process — the TUI dies
before it draws anything. This blob is linked against bionic instead, and needs
only `libm.so`, `libc.so` and `libdl.so`, which Termux provides.

`build.sh` copies it over the npm one in the bun store right before compiling.

### It is version-locked to @opentui/core

The JS half resolves native entry points by symbol name — `createRenderer`,
`render`, `imageCreateFromPixels`, `processKittyImageReply`,
`setKittyImageTransport` and so on. A `.so` built from a different
`@opentui/core` is therefore *missing calls*, not merely out of date: it may
load fine and then crash on first use of a new entry point.

opencode v2 uses `@opentui/core` 0.5.12, which added seven entry points the
previously vendored blob did not have:

```
imageCreateFromPixels   imageUpdatePixels
processKittyImageReply  cancelKittyImageTransport
getKittyImageTransport  pollKittyImageTransport
setKittyImageTransport
```

So **bump `@opentui/core` and rebuild this file.** To regenerate:

```bash
./scripts/build-libopentui.sh                 # version from the opencode checkout
./scripts/build-libopentui.sh 0.5.12         # or explicit
```

or in Docker, if you would rather not install a zig toolchain:

```bash
docker build -t opentui-lib -f Dockerfile.libopentui \
  --build-arg OPENTUI_VERSION=0.5.12 .
```

`DT_NEEDED` of a correct build looks like `libm.so`, `libc.so`, `libdl.so`.
If you see `libc.so.6` you have a glibc object.

### It needs a loader that implements TLSDESC

This is a Zig build, and Zig gives every `threadlocal var` in an `aarch64` shared
object an `R_AARCH64_TLSDESC` relocation. This blob has 11 of them, in Zig's
`std.Io.Threaded.Thread.current`, `std.Thread`'s thread-id and signal-stack
slots, OpenTUI's yoga measure slots, and the vendored C libraries.

A loader that does not implement `R_AARCH64_TLSDESC` leaves those descriptors
zeroed, and the first threadlocal access in the object then does `blr` on a null
resolver: `Segmentation fault at address 0x0`, before any TUI frame. Bionic grew
TLSDESC in 2019, so Android 11 and newer are fine; an older `linker64` is not.
`termux/termux-docker` currently ships one that predates it, which is why the
TUI cannot be exercised in that container — see
[the sigaction patch](#the-sigaction-patch-is-inert) for what is known and what
is not.

A twenty-line Zig library is enough to see it, so this is not OpenTUI-specific:

```zig
threadlocal var counter: u32 = 41;
export fn bump() u32 { return ++counter; }
```

```bash
zig build-lib tls.zig -target aarch64-linux-android -lc -dynamic -fPIC   # R_AARCH64_TLSDESC x2
```

`dlopen` it and call `bump()`: with a loader that implements TLSDESC it returns
42, otherwise the process dies on the first call. To tell the two apart without a
debugger, read the descriptor itself — the linker writes `{resolver, argument}`
at the address the `adrp`/`ldr` pair points at, and it is still all zeros when
the relocation was not applied.

If a device turns out to be affected, the fix is to build the blob with no
`threadlocal` at all, which means patching `std.Io.Threaded`, `std.Thread` and
`packages/native/src/yoga.zig` in addition to this repository's patches. That
is not mechanical: making `std.Io.Threaded.Thread.current` a plain global (the
only one the first stdout write touches) crashes the zig 0.16.0 compiler on this
target rather than producing a `.so`.

### How the build gets a bionic libc out of Zig

Zig bundles only glibc and musl, so for `aarch64-linux-android` it reports
`unable to provide libc` and offers no related target. `build-libopentui.sh`
supplies one by hand, in three parts:

| what | why |
| --- | --- |
| `ZIG_LIBC`, a libc config naming the include and crt dirs | the mechanism Zig reads for a target it cannot provide itself |
| `BIONIC_SYSROOT_INC`, the NDK `usr/include` with the arch dir flattened in | Zig resolves one include dir, but the NDK splits headers across `usr/include` and `usr/include/<triple>` |
| `__opentui/*_shimmed.h`, which expand `_Nullable`/`_Nonnull` to nothing first | translate-c rejects a nullability specifier on an array parameter, and the NDK applies one to `utimes`, `futimes`, `utimensat` and friends |

Two further pieces live in `patches/`:

- `patches/zig/posix-android-sigaction.patch` — bionic's `sigset_t` is 8 bytes
  where Zig's `linux` one is 128, so `posix.sigaction` cannot go through the
  libc wrapper on android and uses the raw syscall instead.
- `patches/opentui/android-libopentui.patch` — points the two `b.addTranslateC`
  steps at the merged include dir. This is the only way their `-I` reaches
  translate-c: a module's `include_dirs` do not, which is why `--sysroot` and
  `addSystemIncludePath` alone leave `math.h` and `pthread.h` unfound.

### The sigaction patch is inert

`patches/zig/posix-android-sigaction.patch` compiles, and the blob it produces
imports `sigaddset`, `sigemptyset`, `sigismember`, `sigpending`, `sigprocmask`
and `sigtimedwait` — but not `sigaction`:

```bash
nm -D --undefined-only libopentui.so | grep sigaction   # no output
```

Zig only type-checks the code a build actually reaches, and a
`ReleaseFast` android build reaches no `posix.sigaction` at all, so the patch
changes nothing here. It is also not type-correct when something *does* reach
it: `std.debug`'s segfault handler calls `posix.sigaction` with a
`c.common_linux_Sigaction`, which the patch's `linux.sigaction` call cannot
accept, so a `Debug` or `ReleaseSafe` build of this blob fails to compile while
the `ReleaseFast` one passes. It is kept only because removing it is a separate
decision: it may still be load-bearing for a future `@opentui/core` that
installs a signal handler, and it costs nothing while unreached.

`patches/zig/cache-no-tmpfile.patch` is not part of the android story. Zig's
build cache creates files with `O_TMPFILE` and hardlinks them into place, and
`linkat(AT_EMPTY_PATH)` needs `CAP_DAC_READ_SEARCH`; sandboxes and proot drop
that capability and Zig aborts. The script applies it only when the capability
is genuinely missing.
