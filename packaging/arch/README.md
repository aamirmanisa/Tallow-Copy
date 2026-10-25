# Arch / CachyOS package

`tallowx` is one Tallow source file compiled by the Tallow engine, so the package
has an unusual shape: the engine is a **build-time and run-time** dependency, and
it is not packaged anywhere. That is a precondition, not an omission.

## Build

```sh
# 1. the engine (once) — it installs `tallow` plus the `libtallow.a` beside it
sudo -S -p '' pacman -S --needed base-devel clang xz bzip2
curl -fsSL https://raw.githubusercontent.com/aamirmanisa/tallowsphere/main/install.sh | bash

# 2. the package
cd packaging/arch
updpkgsums          # once v<pkgver> is tagged upstream
makepkg -si
```

`prepare()` fails with an explicit message if `tallow` or `clang` is missing,
rather than letting `tallow build` fail somewhere in the middle of a compile.

## What the package installs

- `/usr/bin/tallowx` — the compiled binary (it does not need the engine at run
  time; it links the runtime archive statically)
- `/usr/share/tallowx/tallowx.tl` — the source, so the installed tool can be read
  and rebuilt
- licence and README under the usual Arch paths

## Why `check()` runs both suites

`tests/smoke.sh` runs on the interpreter plane and needs nothing but the engine;
`tests/native.sh` rebuilds the binary and exercises the destructive paths
(`--delete`, `--checksum`, `--resume`) against real files. A package that builds
but does not pass those should not be installable.
