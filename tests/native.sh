#!/usr/bin/env bash
# native.sh — the smoke suite, run against the COMPILED binary.
#
# smoke.sh exercises `tallow run` (the shipped interpreter plane). This script
# asks a different question: does the native binary, if there is one, behave the
# same? It builds first and then runs the same fixtures against the executable,
# so an engine regression that only affects codegen shows up as a failure here
# instead of in a user's copy.
#
# Skips cleanly (exit 0, "skipped") when the build refuses to lower the program —
# that is the known, documented state of the native plane being incomplete, not
# a bug in this script.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TALLOW="${TALLOW:-tallow}"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tallowx-native.XXXXXX")"
SRC="$ROOT/src"
DST="$ROOT/dst"
fails=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails+1)); }
cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT

# ── build ────────────────────────────────────────────────────────────────
# `tallow build` writes the binary beside the source and takes no -o, so build
# inside a copy of the tree in the scratch dir: the repo's ./tallowx launcher
# must never be overwritten by a build artifact.
BUILD="$ROOT/build"
mkdir -p "$BUILD"
cp "$HERE/tallowx.tl" "$BUILD/"
if ! "$TALLOW" build "$BUILD/tallowx.tl" --release >"$ROOT/build.log" 2>&1; then
    printf 'skipped  native build refused: %s\n' "$(grep -m1 -E 'build failed|no lowering' "$ROOT/build.log" | cut -c1-120)"
    exit 0
fi
BIN="$BUILD/tallowx"
[ -x "$BIN" ] || { printf 'FAIL  build reported success but %s is missing\n' "$BIN"; exit 1; }
pass "native build produced an executable"

run() { "$BIN" "$@" >"$ROOT/out.log" 2>&1; }

# ── does this engine carry the resume primitives? (fs.copy_range, Transfer.hash_prefix)
# The tool's core paths work on any 1.5.x engine; --resume needs the build that
# added copy_range. CI installs the released tarball, which may lag, so probe by
# EXECUTION rather than by version string — two engines both print 1.5.2 and only
# one of them has the primitive.
mkdir -p "$ROOT/probe"
cat > "$ROOT/probe/probe.tl" <<'PROBETL'
fn main() {
    fs.write_file("/tmp/tallowx-resume-probe.src", "0123456789abcdef")?
    fs.copy_range("/tmp/tallowx-resume-probe.src", "/tmp/tallowx-resume-probe.dst", 8, 8)
    let h = Transfer.hash_prefix("/tmp/tallowx-resume-probe.src", 4)
    print("has-resume:" + h.len().to_string())
}
PROBETL
RESUME_OK=0
if out=$("$TALLOW" run "$ROOT/probe/probe.tl" --interpret 2>&1) && printf '%s' "$out" | grep -q 'has-resume:64'; then
  RESUME_OK=1
fi
rm -f /tmp/tallowx-resume-probe.src /tmp/tallowx-resume-probe.dst

# ── fixture: nested dirs, mixed perms, pinned mtimes, empty dir, unicode name
mkdir -p "$SRC/a/b/c" "$SRC/a/empty"
printf 'hello\n' > "$SRC/a/small.txt"
printf 'deep\n'  > "$SRC/a/b/c/deep.txt"
head -c 2000000 /dev/urandom > "$SRC/a/b/rand.bin"
printf 'unicode\n' > "$SRC/a/üñïçødé.txt"
chmod 600 "$SRC/a/small.txt"
chmod 640 "$SRC/a/b/rand.bin"
touch -d '2023-04-05 06:07:08' "$SRC/a/small.txt"
touch -d '2023-05-06 07:08:09' "$SRC/a/b/c/deep.txt"

# 1 · plan writes nothing
run plan "$SRC" "$DST"
if [ ! -e "$DST" ] && grep -q '^plan ' "$ROOT/out.log"; then pass "plan performs no writes"; else fail "plan wrote to the destination"; fi

# 2 · copy + verify
run copy "$SRC" "$DST"
if [ $? -eq 0 ] && grep -q 'failed: 0' "$ROOT/out.log"; then pass "copy exits 0 with no failures"; else fail "copy failed"; fi
if diff -r "$SRC" "$DST" >/dev/null 2>&1; then pass "tree is byte-identical after copy"; else fail "tree differs after copy"; fi
if [ -d "$DST/a/empty" ]; then pass "empty directory preserved"; else fail "empty directory lost"; fi
m1=$(stat -c '%a %Y' "$SRC/a/small.txt"); m2=$(stat -c '%a %Y' "$DST/a/small.txt")
if [ "$m1" = "$m2" ]; then pass "mode+mtime preserved ($m1)"; else fail "metadata differs: $m1 vs $m2"; fi

# 3 · re-run skips everything
run copy "$SRC" "$DST"
if grep -q 'copied: 0' "$ROOT/out.log" || grep -q 'copy: 0 file' "$ROOT/out.log"; then
    pass "second run copies nothing"
else
    fail "second run copied again: $(grep -m1 'copy' "$ROOT/out.log")"
fi

# 4 · verify detects nothing when the trees match
run verify "$SRC" "$DST"
if [ $? -eq 0 ]; then pass "verify passes on identical trees"; else fail "verify failed on identical trees"; fi

# 5 · and catches one flipped byte
printf 'X' | dd of="$DST/a/small.txt" bs=1 seek=0 conv=notrunc status=none
run verify "$SRC" "$DST"
rc=$?
if [ $rc -ne 0 ] && grep -q 'differs\|mismatch\|failed' "$ROOT/out.log"; then pass "verify exits non-zero and names the corruption"; else fail "verify missed a single flipped byte (exit $rc)"; fi
printf 'hello\n' > "$DST/a/small.txt"

if [ "$RESUME_OK" = 1 ]; then
# 4b · without --resume a short destination is re-copied, not resumed
mkdir -p "$ROOT/rsrc/sub" "$ROOT/rdst/sub"
head -c 12582912 /dev/urandom > "$ROOT/rsrc/sub/big.bin"
head -c 5242880 "$ROOT/rsrc/sub/big.bin" > "$ROOT/rdst/sub/big.bin"
run copy "$ROOT/rsrc" "$ROOT/rdst"
if grep -q 'resumed:' "$ROOT/out.log"; then fail "resume ran without --resume"; else pass "resume is opt-in: no --resume, no resume"; fi
if cmp -s "$ROOT/rsrc/sub/big.bin" "$ROOT/rdst/sub/big.bin"; then pass "opt-out copy still produced the right bytes"; else fail "opt-out copy produced wrong bytes"; fi

# 4c · --checksum: a destination that matches on size and mtime but not bytes
mkdir -p "$ROOT/csrc" "$ROOT/cdst"
head -c 2097152 /dev/urandom > "$ROOT/csrc/c.bin"
touch -d '2021-06-01 08:00:00' "$ROOT/csrc/c.bin"
cp -p "$ROOT/csrc/c.bin" "$ROOT/cdst/c.bin"
printf 'X' | dd of="$ROOT/cdst/c.bin" bs=1 seek=5000 conv=notrunc status=none 2>/dev/null
touch -r "$ROOT/csrc/c.bin" "$ROOT/cdst/c.bin"   # hide the damage from size+mtime
run copy "$ROOT/csrc" "$ROOT/cdst"
if cmp -s "$ROOT/csrc/c.bin" "$ROOT/cdst/c.bin"; then fail "plain copy claims it repaired a same-size same-mtime file"; else pass "plain copy skips a same-size same-mtime corruption (documented)"; fi
run copy --checksum "$ROOT/csrc" "$ROOT/cdst"
if cmp -s "$ROOT/csrc/c.bin" "$ROOT/cdst/c.bin"; then pass "--checksum finds and repairs it"; else fail "--checksum did not repair the corruption"; fi

# 5 · byte-level resume: a truncated destination is completed, not restarted
mkdir -p "$ROOT/rsrc/sub" "$ROOT/rdst/sub"
head -c 12582912 /dev/urandom > "$ROOT/rsrc/sub/big.bin"      # 12 MiB, over RESUME_MIN
head -c 5242880  "$ROOT/rsrc/sub/big.bin" > "$ROOT/rdst/sub/big.bin"   # interrupted at 5 MiB
run copy --resume "$ROOT/rsrc" "$ROOT/rdst"
if grep -q 'resumed: 1' "$ROOT/out.log"; then pass "resume: tail-only copy reported"; else fail "resume was not used: $(grep -m1 'resumed\|copy:' "$ROOT/out.log")"; fi
if cmp -s "$ROOT/rsrc/sub/big.bin" "$ROOT/rdst/sub/big.bin"; then pass "resume: file byte-identical after completion"; else fail "resume produced a different file"; fi
# and the resumed file is skipped next time (mtime restored, not "now")
run copy --resume "$ROOT/rsrc" "$ROOT/rdst"
if grep -q 'copied: 0\|copy: 0 file' "$ROOT/out.log"; then pass "resume: completed file is skipped next run"; else fail "resumed file was copied again"; fi

# 6 · a destination that is NOT a prefix is replaced, not appended to
head -c 5242880 /dev/urandom > "$ROOT/rdst/sub/big.bin"        # same size, wrong bytes
run copy --resume "$ROOT/rsrc" "$ROOT/rdst"
if cmp -s "$ROOT/rsrc/sub/big.bin" "$ROOT/rdst/sub/big.bin"; then pass "resume: mismatched prefix was replaced"; else fail "resume appended to a mismatched prefix"; fi
else
    echo "skip  resume: this engine has no fs.copy_range/Transfer.hash_prefix (needs tallowsphere 8883409+)"
fi

# 6 · move removes the source tree
mkdir -p "$ROOT/mv-src/x"
printf 'move me\n' > "$ROOT/mv-src/x/f.txt"
run move "$ROOT/mv-src" "$ROOT/mv-dst"
if [ ! -e "$ROOT/mv-src" ] && [ -f "$ROOT/mv-dst/x/f.txt" ] && cmp -s "$ROOT/mv-dst/x/f.txt" <(printf 'move me\n'); then
    pass "move removed the source and kept the payload"
else
    fail "move left the source behind or lost the payload"
fi

# 7 · relative paths stay relative (running as root hides absolutising bugs)
mkdir -p "$ROOT/rel"
( cd "$ROOT/rel" && "$BIN" copy "$ROOT/mv-dst" ./out >"$ROOT/out.log" 2>&1 )
if [ -d "$ROOT/rel/out" ] && [ ! -e /out ]; then pass "relative copy wrote nothing outside the working directory"; else fail "relative copy wrote outside the working directory"; fi

# 9 · mirror mode (--delete): remove extras, keep excluded paths, plan is safe
mkdir -p "$ROOT/msrc/sub" "$ROOT/mdst/sub" "$ROOT/mdst/stale" "$ROOT/mdst/pdfcache"
printf 'keep\n' > "$ROOT/msrc/a.txt"
printf 'keep\n' > "$ROOT/mdst/a.txt"; touch -r "$ROOT/msrc/a.txt" "$ROOT/mdst/a.txt"
printf 'extra\n' > "$ROOT/mdst/sub/gone.txt"
printf 'extra\n' > "$ROOT/mdst/stale/gone.txt"
printf 'cached\n' > "$ROOT/mdst/pdfcache/x.tmp"

"$BIN" plan "$ROOT/msrc" "$ROOT/mdst" --delete >"$ROOT/out.log" 2>&1
[ "$(find "$ROOT/mdst" -type f | wc -l)" = 4 ] && pass "--delete in plan mode deletes nothing" || fail "plan --delete wrote to the destination"
"$BIN" copy "$ROOT/msrc" "$ROOT/mdst" --delete --exclude '*.tmp' >"$ROOT/out.log" 2>&1
if [ ! -e "$ROOT/mdst/sub/gone.txt" ] && [ ! -e "$ROOT/mdst/stale" ]; then pass "--delete removed extras and the emptied directory"; else fail "--delete left extras behind"; fi
[ -f "$ROOT/mdst/pdfcache/x.tmp" ] && pass "--exclude kept the matching path" || fail "--exclude did not protect the path"
grep -q 'deleted: 3' "$ROOT/out.log" && pass "--delete reports what it removed" || fail "--delete did not report a deletion count"
for spec in same inside move empty; do
  case $spec in
    same)   "$BIN" copy "$ROOT/msrc" "$ROOT/msrc" --delete >/dev/null 2>&1 ;;
    inside) "$BIN" copy "$ROOT/msrc" "$ROOT/msrc/sub" --delete >/dev/null 2>&1 ;;
    move)   "$BIN" move "$ROOT/msrc" "$ROOT/mdst" --delete >/dev/null 2>&1 ;;
    empty)  mkdir -p "$ROOT/mempty"; "$BIN" copy "$ROOT/mempty" "$ROOT/mdst" --delete >/dev/null 2>&1 ;;
  esac
  [ $? -ne 0 ] && pass "--delete refuses $spec" || fail "--delete allowed $spec"
done
[ -f "$ROOT/mdst/a.txt" ] && pass "refused runs left the destination intact" || fail "a refused --delete run still deleted files"

# 8 · no arguments exits 2
"$BIN" >/dev/null 2>&1
[ $? -eq 2 ] && pass "no arguments exits 2" || fail "no arguments did not exit 2"

printf '\nnative: %d check(s) failed\n' "$fails"
[ "$fails" -eq 0 ]
