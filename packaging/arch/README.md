# Arch / CachyOS package

`tallowx` is one Tallow source file compiled by the Tallow engine, so the package
has an unusual shape: the engine is a **build-time and run-time** dependency, and
it is not packaged anywhere. That is a precondition, not an omission.

## Build

```sh
# 1. the engine (once) — it installs `tallow` plus the `libtallow.a` beside it.
#    Do not pipe a script from a branch into a shell: fetch a tagged release,
#    verify its published checksum, then run what you verified.
sudo -S -p '' pacman -S --needed base-devel clang xz bzip2
ver=1.6.0
curl -fsSLO "https://github.com/aamirmanisa/tallowsphere/releases/download/v${ver}/install.sh"
curl -fsSLO "https://github.com/aamirmanisa/tallowsphere/releases/download/v${ver}/install.sh.sha256"
sha256sum -c "install.sh.sha256" && bash install.sh

# 2. the package
cd packaging/arch
updpkgsums          # once v<pkgver> is tagged upstream
makepkg -si
```

`prepare()` fails with an explicit message if `tallow` or `clang` is missing,
rather than letting `tallow build` fail somewhere in the middle of a compile.

## What the package installs

- `/usr/bin/tallowx` — a two-line PATH entry that execs the launcher
- `/usr/lib/tallowx/tallowx` — the launcher; it prefers a native binary and runs
  the interpreter otherwise
- `/usr/lib/tallowx/tallowx.tl` — the source, so the installed tool can be read
  and rebuilt
- `/usr/lib/tallowx/build/tallowx` — present only when the native build succeeded
- licence and README under the usual Arch paths

As of engine 1.7.0 the compiled plane cannot lower `Array.push`, so `tallow
build` refuses this program by name and `build()` keeps going: the package ships
the launcher and runs on the interpreter plane. The native binary is installed
when a future engine can build it, and the launcher picks it up automatically.

## Why `check()` runs both suites

`tests/smoke.sh` runs on the interpreter plane and needs nothing but the engine;
`tests/native.sh` rebuilds the binary and exercises the destructive paths
(`--delete`, `--checksum`, `--resume`) against real files. A package that builds
but does not pass those should not be installable.
