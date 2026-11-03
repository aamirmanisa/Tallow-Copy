#!/usr/bin/env bash
# Run the PKGBUILD's steps without makepkg: prepare → build → package → install
# checks. Used where pacman/makepkg does not exist (this box is Ubuntu), and as a
# fast regression check that the recipe still describes the tree.
set -euo pipefail

SRC=${1:-$(cd "$(dirname "$0")/../.." && pwd)}
WORK=$(mktemp -d /tmp/tallowx-pkg.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
PKGVER=$(sed -n 's/^pkgver=//p' "$SRC/packaging/arch/PKGBUILD")
STAGE="$WORK/tallowx-$PKGVER"

echo "recipe: pkgver=$PKGVER  src=$SRC"
mkdir -p "$STAGE"
( cd "$SRC" && tar -cf - --exclude=.git --exclude=build . ) | ( cd "$STAGE" && tar -xf - )

# ── prepare() ───────────────────────────────────────────────────────────
command -v tallow >/dev/null || { echo "FAIL prepare: tallow not on PATH"; exit 1; }
command -v clang  >/dev/null || { echo "FAIL prepare: clang not on PATH"; exit 1; }
echo "ok   prepare: engine $(tallow --version | head -1), clang present"

# ── build() ─────────────────────────────────────────────────────────────
# The compiled plane cannot lower Array.push as of engine 1.7.0, so `tallow
# build` refuses this program BY NAME. That is not a packaging failure: the
# launcher prefers a native binary when one exists and runs the interpreter
# otherwise, so the recipe keeps the fast path when it builds and ships the
# launcher when it does not — saying which, rather than asserting a plane the
# engine does not have.
cd "$STAGE"
mkdir -p build
cp tallowx.tl build/
if ( cd build && tallow build tallowx.tl --release >build.log 2>&1 ); then
  ./build/tallowx --help >/dev/null || { echo "FAIL build: binary does not run"; exit 1; }
  echo "ok   build: native binary $(stat -c%s build/tallowx) bytes, runs"
else
  echo "note build: native plane refused — $(tail -1 build/build.log)"
  rm -f build/tallowx
  echo "ok   build: launcher + source packaged, interpreter plane"
fi

# ── package() ───────────────────────────────────────────────────────────
PKGDIR="$WORK/pkg"
LIBDIR="$PKGDIR/usr/lib/tallowx"
# The launcher resolves tallowx.tl (and any native build) relative to its own
# directory, so both live in /usr/lib/tallowx and /usr/bin/tallowx is a two-line
# PATH entry. This is what lets one package work on either plane.
install -Dm755 tallowx    "$LIBDIR/tallowx"
install -Dm644 tallowx.tl "$LIBDIR/tallowx.tl"
if [ -x build/tallowx ]; then
  install -Dm755 build/tallowx "$LIBDIR/build/tallowx"
fi
install -Dm644 README.md "$PKGDIR/usr/share/doc/tallowx/README.md"
install -Dm644 LICENSE   "$PKGDIR/usr/share/licenses/tallowx/LICENSE"
mkdir -p "$PKGDIR/usr/bin"
printf '%s\n' '#!/bin/sh' \
  '# The launcher resolves its source and any native build next to itself,' \
  '# so it lives in /usr/lib/tallowx and this is the PATH entry.' \
  'exec /usr/lib/tallowx/tallowx "$@"' > "$PKGDIR/usr/bin/tallowx"
chmod 755 "$PKGDIR/usr/bin/tallowx"
for f in usr/bin/tallowx usr/lib/tallowx/tallowx usr/lib/tallowx/tallowx.tl \
         usr/share/doc/tallowx/README.md usr/share/licenses/tallowx/LICENSE; do
  [ -e "$PKGDIR/$f" ] || { echo "FAIL package: missing $f"; exit 1; }
done
grep -q '^exec /usr/lib/tallowx/tallowx' "$PKGDIR/usr/bin/tallowx" \
  || { echo "FAIL package: PATH entry does not exec the launcher"; exit 1; }
echo "ok   package: $(find "$PKGDIR" -type f | wc -l) files"

# The installed launcher must work without the repo around it. The PATH entry's
# absolute target only resolves on a real root, so its text is asserted above and
# the launcher itself is what runs here.
cd "$WORK"
"$LIBDIR/tallowx" --help | head -1
mkdir -p inst/src inst/dst && printf 'x\n' > inst/src/f
"$LIBDIR/tallowx" copy inst/src inst/dst >/dev/null
cmp -s inst/src/f inst/dst/f || { echo "FAIL installed launcher does not copy"; exit 1; }
echo "ok   installed launcher copies a file from outside the tree"

# ── check() (the fast half) ─────────────────────────────────────────────
cd "$STAGE" && bash tests/smoke.sh | tail -1
echo "PASS recipe verified"
