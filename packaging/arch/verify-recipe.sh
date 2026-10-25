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
cd "$STAGE"
mkdir -p build
cp tallowx.tl build/
( cd build && tallow build tallowx.tl --release >/dev/null )
[ -x build/tallowx ] || { echo "FAIL build: no binary"; exit 1; }
./build/tallowx --help >/dev/null || { echo "FAIL build: binary does not run"; exit 1; }
echo "ok   build: $(stat -c%s build/tallowx) byte binary runs"

# ── package() ───────────────────────────────────────────────────────────
PKGDIR="$WORK/pkg"
install -Dm755 build/tallowx "$PKGDIR/usr/bin/tallowx"
install -Dm644 tallowx.tl      "$PKGDIR/usr/share/tallowx/tallowx.tl"
install -Dm644 README.md       "$PKGDIR/usr/share/doc/tallowx/README.md"
install -Dm644 LICENSE         "$PKGDIR/usr/share/licenses/tallowx/LICENSE"
for f in usr/bin/tallowx usr/share/tallowx/tallowx.tl usr/share/doc/tallowx/README.md usr/share/licenses/tallowx/LICENSE; do
  [ -e "$PKGDIR/$f" ] || { echo "FAIL package: missing $f"; exit 1; }
done
echo "ok   package: $(find "$PKGDIR" -type f | wc -l) files"

# the installed binary must work without the repo around it
cd "$WORK"
"$PKGDIR/usr/bin/tallowx" --help | head -1
mkdir -p inst/src inst/dst && printf 'x\n' > inst/src/f
"$PKGDIR/usr/bin/tallowx" copy inst/src inst/dst >/dev/null
cmp -s inst/src/f inst/dst/f || { echo "FAIL installed binary does not copy"; exit 1; }
echo "ok   installed binary copies a file from outside the tree"

# ── check() (the fast half) ─────────────────────────────────────────────
cd "$STAGE" && bash tests/smoke.sh | tail -1
echo "PASS recipe verified"
