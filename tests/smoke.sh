#!/usr/bin/env bash
# smoke.sh — end-to-end checks for tallowx on a scratch tree.
#
# Every assertion is a real command with a real exit status; nothing is
# "verified" by inspection. Requires `tallow` on PATH (engine 1.5.2).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TL="$HERE/tallowx.tl"
TALLOW="${TALLOW:-tallow}"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tallowx-smoke.XXXXXX")"
SRC="$ROOT/src"
DST="$ROOT/dst"
fails=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails+1)); }

cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT

run() { "$TALLOW" run "$TL" -- "$@" >"$ROOT/out.log" 2>&1; }

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
if grep -q 'skipped: 4' "$ROOT/out.log" && grep -q 'copied: 0' "$ROOT/out.log" || grep -q 'copy: 0 file' "$ROOT/out.log"; then
  pass "second run is a no-op (skip-if-identical)"
else
  fail "second run copied again"; tail -3 "$ROOT/out.log"
fi

# 4 · corruption is caught
python3 - "$DST/a/small.txt" <<'PY'
import sys
p = sys.argv[1]
b = bytearray(open(p, 'rb').read())
b[0] ^= 0xFF
open(p, 'wb').write(b)
PY
run verify "$SRC" "$DST"; rc=$?
if [ $rc -eq 1 ] && grep -q 'mismatch' "$ROOT/out.log"; then pass "verify exits 1 and names the bad file"; else fail "verify missed a corrupted file (rc=$rc)"; fi

# 5 · single-file copy
rm -rf "$ROOT/one.bin"
run copy "$SRC/a/b/rand.bin" "$ROOT/one.bin"
if cmp -s "$SRC/a/b/rand.bin" "$ROOT/one.bin"; then pass "single-file copy is identical"; else fail "single-file copy differs"; fi

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

# 6 · move removes verified sources, leaves nothing behind
MVS="$ROOT/mvsrc"; MVD="$ROOT/mvdst"
cp -a "$SRC" "$MVS"
run move "$MVS" "$MVD"
left=$(find "$MVS" -type f | wc -l)
if [ "$left" -eq 0 ] && diff -r "$SRC" "$MVD" >/dev/null 2>&1; then pass "move empties the source and copies cleanly"; else fail "move left $left file(s) or copied wrong"; fi

# 7 · relative paths work (mkdir_p must not absolutise them)
mkdir -p "$ROOT/rel" && cp -a "$SRC" "$ROOT/rel/src"
( cd "$ROOT/rel" && "$TALLOW" run "$TL" -- copy src dst >"$ROOT/rel.log" 2>&1 )
if [ $? -eq 0 ] && diff -r "$SRC" "$ROOT/rel/dst" >/dev/null 2>&1; then pass "relative source and destination"; else fail "relative paths broken"; tail -3 "$ROOT/rel.log"; fi
# A relative destination must never resolve to an absolute path. Running as
# root hides that bug (mkdir /dst succeeds), so assert it directly.
if [ -e /dst ]; then fail "relative copy created an absolute /dst"; rmdir /dst/a/b/c /dst/a/b /dst/a /dst 2>/dev/null; else pass "relative copy wrote nothing outside the working directory"; fi

# 9 · mirror mode (--delete): remove extras, keep excluded paths, plan is safe
mkdir -p "$ROOT/msrc/sub" "$ROOT/mdst/sub" "$ROOT/mdst/stale" "$ROOT/mdst/pdfcache"
printf 'keep\n' > "$ROOT/msrc/a.txt"
printf 'keep\n' > "$ROOT/mdst/a.txt"; touch -r "$ROOT/msrc/a.txt" "$ROOT/mdst/a.txt"
printf 'extra\n' > "$ROOT/mdst/sub/gone.txt"
printf 'extra\n' > "$ROOT/mdst/stale/gone.txt"
printf 'cached\n' > "$ROOT/mdst/pdfcache/x.tmp"

XC="run"
run plan "$ROOT/msrc" "$ROOT/mdst" --delete
[ "$(find "$ROOT/mdst" -type f | wc -l)" = 4 ] && pass "--delete in plan mode deletes nothing" || fail "plan --delete wrote to the destination"
run copy "$ROOT/msrc" "$ROOT/mdst" --delete --exclude '*.tmp'
if [ ! -e "$ROOT/mdst/sub/gone.txt" ] && [ ! -e "$ROOT/mdst/stale" ]; then pass "--delete removed extras and the emptied directory"; else fail "--delete left extras behind"; fi
[ -f "$ROOT/mdst/pdfcache/x.tmp" ] && pass "--exclude kept the matching path" || fail "--exclude did not protect the path"
grep -q 'deleted: 3' "$ROOT/out.log" && pass "--delete reports what it removed" || fail "--delete did not report a deletion count"
for spec in same inside move empty; do
  case $spec in
    same)   run copy "$ROOT/msrc" "$ROOT/msrc" --delete ;;
    inside) run copy "$ROOT/msrc" "$ROOT/msrc/sub" --delete ;;
    move)   run move "$ROOT/msrc" "$ROOT/mdst" --delete ;;
    empty)  mkdir -p "$ROOT/mempty"; run copy "$ROOT/mempty" "$ROOT/mdst" --delete ;;
  esac
  [ $? -ne 0 ] && pass "--delete refuses $spec" || fail "--delete allowed $spec"
done
[ -f "$ROOT/mdst/a.txt" ] && pass "refused runs left the destination intact" || fail "a refused --delete run still deleted files"

# 8 · usage exit code
"$TALLOW" run "$TL" >"$ROOT/out.log" 2>&1; rc=$?
if [ $rc -eq 2 ]; then pass "no arguments exits 2"; else fail "usage exit code was $rc"; fi

echo
if [ "$fails" -eq 0 ]; then
  echo "smoke: all checks passed"
else
  echo "smoke: $fails check(s) failed"
  exit 1
fi
