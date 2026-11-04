#!/usr/bin/env python3
"""Verified-vs-verified comparison: the table in docs/PERFORMANCE-ANALYSIS.md.

`bench.py` compares each tool to the others without saying whether they verify,
which measures the guarantee rather than the copy. `cp -a` and `rsync -a` do not
read the bytes back; a verified tool does. This harness labels every row.

    TALLOW=/path/to/tallow \
    TALLOWX=/path/to/tallowx.tl \
    NATIVE=/path/to/built/tallowx \
    BENCH_DIR=/path/with/big.bin/and/tree \
    python3 bench/verified_comparison.py

`BENCH_DIR` must contain `big.bin` (one large file) and `tree/` (a directory of
small files); `bench.py` generates both if you point it at the same directory.
"""
import os
import shutil
import statistics
import subprocess
import sys
import time

WORK = os.environ.get("BENCH_DIR", "/tmp/txbench")
BIG = os.path.join(WORK, "big.bin")
TREE = os.path.join(WORK, "tree")
OUT = os.path.join(WORK, "out.bin")
OUTTREE = os.path.join(WORK, "outtree")
TALLOW = os.environ.get("TALLOW", "tallow")
TALLOWX = os.environ.get("TALLOWX", "tallowx.tl")
NATIVE = os.environ.get("NATIVE")
RUNS = int(os.environ.get("RUNS", "3"))


def timed(cmd):
    if isinstance(cmd, str):
        cmd = ["bash", "-c", cmd]
    t0 = time.monotonic()
    p = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ms = (time.monotonic() - t0) * 1000.0
    if p.returncode != 0:
        raise RuntimeError(f"failed ({p.returncode}): {' '.join(cmd)[:120]}")
    return ms


def bench(cases):
    rows = []
    for label, verifies, setup, cmd in cases:
        times = []
        for _ in range(RUNS):
            setup()
            try:
                times.append(timed(cmd))
            except RuntimeError as err:
                print(f"  {label}: {err}")
                break
        if times:
            rows.append((label, verifies, statistics.median(times)))
    if not rows:
        return
    base = min(r[2] for r in rows)
    for label, verifies, med in sorted(rows, key=lambda r: r[2]):
        flag = "verified  " if verifies else "unverified"
        print(f"  {label:<32} {flag} {med:8.1f} ms   x{med/base:5.2f}")


def rm_bin():
    if os.path.exists(OUT):
        os.unlink(OUT)


def rm_tree():
    shutil.rmtree(OUTTREE, ignore_errors=True)


def main():
    if not NATIVE:
        sys.exit("set NATIVE to a tallowx binary built with scripts/build-native.sh")

    print("== A: one large file (all verified except cp/rsync plain)")
    bench([
        ("cp -a", False, rm_bin, ["cp", "-a", BIG, OUT]),
        ("cp -a + sha256sum both", True, rm_bin,
         f"cp -a {BIG} {OUT} && sha256sum {BIG} {OUT}"),
        ("rsync -a --checksum", True, rm_bin, ["rsync", "-a", "--checksum", BIG, OUT]),
        ("tallowx native", True, rm_bin, [NATIVE, "copy", BIG, OUT]),
        ("tallowx interpret", True, rm_bin,
         [TALLOW, "run", "--interpret", TALLOWX, "--", "copy", BIG, OUT]),
    ])

    print("\n== B: many small files (all verified except cp/rsync plain)")
    bench([
        ("cp -a", False, rm_tree, ["cp", "-a", TREE, OUTTREE]),
        ("rsync -a --checksum", True, rm_tree,
         ["rsync", "-a", "--checksum", TREE + "/", OUTTREE + "/"]),
        ("tallowx native", True, rm_tree, [NATIVE, "copy", TREE, OUTTREE]),
        ("tallowx interpret", True, rm_tree,
         [TALLOW, "run", "--interpret", TALLOWX, "--", "copy", TREE, OUTTREE]),
    ])


if __name__ == "__main__":
    main()
