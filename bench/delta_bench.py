#!/usr/bin/env python3
"""Incremental-update benchmark: what each tool actually moves when 1 MiB of a
256 MiB file changes at offset 100 MiB.

The bulk harness (bench.py) copies into an empty destination every time, so it
measures a full transfer. Re-running against an *existing* destination is the
case where rsync's delta algorithm and xdelta3's binary patch are supposed to
win, and where a whole-file copier cannot.

    python3 bench/delta_bench.py

Measures, per tool: wall time of the incremental update, and the final
destination's sha256 against the changed source. A fast number from a wrong
copy cannot reach the table.
"""
import hashlib
import json
import os
import shutil
import statistics
import subprocess
import sys
import time

RUNS = int(os.environ.get("DELTA_RUNS", "3"))
SIZE_MIB = int(os.environ.get("DELTA_SIZE_MIB", "256"))
PATCH_OFFSET_MIB = int(os.environ.get("DELTA_OFFSET_MIB", "100"))
PATCH_MIB = int(os.environ.get("DELTA_PATCH_MIB", "1"))

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TALLOWX = os.path.join(ROOT, "tallowx.tl")
WORK = os.environ.get("TALLOWX_BENCH_DIR") or "/tmp/tallowx-delta"

TALLOW = shutil.which("tallow")


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run(cmd):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} exited {p.returncode}: {p.stderr.decode()[:300]}")
    return p.stdout.decode(errors="replace")


def make_dataset():
    os.makedirs(WORK, exist_ok=True)
    src = os.path.join(WORK, "src.bin")
    if not (os.path.exists(src) and os.path.getsize(src) == SIZE_MIB << 20):
        with open(src, "wb") as fh:
            block = os.urandom(1 << 20)
            for _ in range(SIZE_MIB):
                fh.write(block)
    old = os.path.join(WORK, "old.bin")
    shutil.copyfile(src, old)
    # Change PATCH_MIB at PATCH_OFFSET_MIB: the old copy is what each tool
    # starts from, so this is a genuine partial change, not a new file.
    with open(src, "r+b") as fh:
        fh.seek(PATCH_OFFSET_MIB << 20)
        fh.write(os.urandom(PATCH_MIB << 20))
    return src, old


def bench_tallowx(src, old, dst):
    run([TALLOW, "run", TALLOWX, "--", "copy", src, dst])


def bench_rsync(src, old, dst):
    run(["rsync", "-a", "--no-whole-file", src, dst])


def bench_xdelta(src, old, dst):
    patch = os.path.join(WORK, "update.vcdiff")
    run(["xdelta3", "-f", "-e", "-s", old, src, patch])
    run(["xdelta3", "-f", "-d", "-s", old, patch, dst])


TOOLS = [
    ("tallowx copy", bench_tallowx),
    ("rsync -a --no-whole-file", bench_rsync),
    ("xdelta3 patch+apply", bench_xdelta),
]


def main():
    if not TALLOW:
        sys.exit("tallow not on PATH")
    src, old = make_dataset()
    want = sha(src)
    rows = []
    for name, fn in TOOLS:
        times = []
        ok = True
        for i in range(RUNS):
            dst = os.path.join(WORK, f"dst-{i}.bin")
            shutil.copyfile(old, dst)  # every run starts from the old version
            t0 = time.monotonic()
            try:
                fn(src, old, dst)
            except RuntimeError as err:
                print(f"  {name}: FAILED {err}", file=sys.stderr)
                ok = False
                break
            times.append((time.monotonic() - t0) * 1000.0)
            ok = ok and sha(dst) == want
            os.unlink(dst)
        if times:
            rows.append(
                {
                    "tool": name,
                    "runs_ms": [round(t, 1) for t in times],
                    "median_ms": round(statistics.median(times), 1),
                    "integrity_ok": ok,
                }
            )
    patch = os.path.join(WORK, "update.vcdiff")
    patch_bytes = os.path.getsize(patch) if os.path.exists(patch) else None

    out = {
        "dataset": f"{SIZE_MIB} MiB file, {PATCH_MIB} MiB changed at offset {PATCH_OFFSET_MIB} MiB",
        "runs": RUNS,
        "xdelta_patch_bytes": patch_bytes,
        "rows": sorted(rows, key=lambda r: r["median_ms"]),
    }
    print(json.dumps(out, indent=2))
    with open(os.path.join(HERE, "delta-results.json"), "w") as fh:
        json.dump(out, fh, indent=2)


if __name__ == "__main__":
    main()
