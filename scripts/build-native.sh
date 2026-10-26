#!/usr/bin/env bash
# build-native.sh — compile tallowx into build/ and record the engine that did it.
#
# `tallow build` writes the binary beside its source, so building tallowx.tl in
# the repository root would overwrite the ./tallowx launcher with a ~110 MB ELF.
# This script builds inside build/ (gitignored) and writes build/engine-version,
# which the launcher compares before it trusts the binary: a native build is
# only valid for the source AND the engine that produced it.
#
#   ./scripts/build-native.sh
#   TALLOW=/path/to/tallow ./scripts/build-native.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${TALLOW:-tallow}"
BUILD="$HERE/build"

if ! command -v "$ENGINE" >/dev/null 2>&1; then
    echo "build-native: engine '$ENGINE' not on PATH (set TALLOW=/path/to/tallow)" >&2
    exit 2
fi

# A debug-built engine links an unoptimised libtallow.a, and every FFI call in
# the resulting binary runs unoptimised — measured at ~10x slower hashing. Say
# so rather than leaving a surprising binary in build/.
engine_version="$("$ENGINE" --version | head -1)"
case "$engine_version" in
    *debug*) echo "build-native: warning: engine looks like a debug build ($engine_version)" >&2 ;;
esac

mkdir -p "$BUILD"
cp "$HERE/tallowx.tl" "$BUILD/tallowx.tl"

echo "build-native: $engine_version -> $BUILD/tallowx"
( cd "$BUILD" && "$ENGINE" build tallowx.tl --release )

if [ ! -x "$BUILD/tallowx" ]; then
    echo "build-native: the build reported success but $BUILD/tallowx is missing" >&2
    exit 1
fi

printf '%s\n' "$engine_version" > "$BUILD/engine-version"
echo "build-native: ok — $("$BUILD/tallowx" --version 2>/dev/null | head -1 || echo 'version probe skipped')"
