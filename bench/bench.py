#!/usr/bin/env python3
"""Benchmark tallowx against cp and rsync.

Two datasets, both generated if missing:

  A. one 256 MiB file              — bulk throughput
  B. 2,000 small files / 40 dirs   — per-file and metadata cost

Every command copies into a freshly removed destination. Three runs each; the
median is reported. Integrity is checked once per tool, after the last run
(sha256 for A, recursive diff for B), so a fast number from a broken copy
cannot reach the table.

    python3 bench/bench.py
    TALLOWX_BENCH_DIR=/mnt/nas/bench python3 bench/bench.py

Point TALLOWX_BENCH_DIR at the filesystem you care about (a NAS mount, say);
the default is a fresh temp directory on the current filesystem.
"""
import hashlib
import json
import os
import random
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

RUNS = 3
BIG_MIB = 256
SMALL_DIRS = 40
SMALL_FILES = 50

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TALLOWX = os.path.join(ROOT, "tallowx.tl")
OUT = os.path.join(HERE, "results.json")


def timed(cmd):
    t0 = time.monotonic()
    p = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ms = (time.monotonic() - t0) * 1000.0
    if p.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} exited {p.returncode}")
    return ms


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def make_big(path):
    if os.path.exists(path) and os.path.getsize(path) == BIG_MIB << 20:
        return
    with open(path, "wb") as fh:
        for _ in range(BIG_MIB):
            fh.write(os.urandom(1 << 20))


def make_tree(root):
    if os.path.isdir(root) and sum(len(f) for _, _, f in os.walk(root)) == SMALL_DIRS * SMALL_FILES:
        return
    shutil.rmtree(root, ignore_errors=True)
    rnd = random.Random(7)
    for d in range(SMALL_DIRS):
        sub = os.path.join(root, f"dir{d:02d}")
        os.makedirs(sub)
        for f in range(SMALL_FILES):
            with open(os.path.join(sub, f"f{f:03d}.bin"), "wb") as fh:
                fh.write(os.urandom(rnd.choice([1024, 2048, 4096, 8192])))


def bench(label, src, dst, cmds, integrity):
    rows = []
    for name, mk in cmds:
        times = []
        for _ in range(RUNS):
            if os.path.exists(dst):
                shutil.rmtree(dst) if os.path.isdir(dst) else os.remove(dst)
            times.append(timed(mk(src, dst)))
        ok = integrity(src, dst)
        rows.append({"tool": name, "runs_ms": [round(t, 1) for t in times],
                     "median_ms": round(statistics.median(times), 1),
                     "integrity_ok": ok})
        if os.path.exists(dst):
            shutil.rmtree(dst) if os.path.isdir(dst) else os.remove(dst)
    return {"dataset": label, "rows": rows}


def main():
    tallow = shutil.which("tallow")
    if not tallow:
        sys.exit("tallow not on PATH (install the engine first)")

    work = os.environ.get("TALLOWX_BENCH_DIR") or tempfile.mkdtemp(prefix="tallowx-bench.")
    os.makedirs(work, exist_ok=True)
    big = os.path.join(work, "big.bin")
    tree = os.path.join(work, "tree")
    make_big(big)
    make_tree(tree)

    def cmd(*args):
        return lambda s, d: [tallow, "run", TALLOWX, "--", *args, s, d]

    copy_cmds = [
        ("cp -a", lambda s, d: ["cp", "-a", s, d]),
        ("rsync -a", lambda s, d: ["rsync", "-a", s, d]),
        ("tallowx (verify)", cmd("copy")),
        ("tallowx --no-verify", cmd("copy", "--no-verify")),
    ]
    tree_cmds = [
        ("cp -a", lambda s, d: ["cp", "-a", s, d]),
        ("rsync -a", lambda s, d: ["rsync", "-a", s + "/", d + "/"]),
        ("tallowx (verify)", cmd("copy")),
        ("tallowx --no-verify", cmd("copy", "--no-verify")),
    ]

    results = {
        "engine": subprocess.run([tallow, "--version"], capture_output=True, text=True).stdout.strip(),
        "host": os.uname().machine,
        "workdir": work,
        "runs": RUNS,
        "datasets": [],
    }
    results["datasets"].append(bench(
        f"A: one {BIG_MIB} MiB file", big, os.path.join(work, "out.bin"), copy_cmds,
        lambda s, d: os.path.exists(d) and sha(s) == sha(d)))
    results["datasets"].append(bench(
        f"B: {SMALL_DIRS * SMALL_FILES:,} files / {SMALL_DIRS} dirs",
        tree, os.path.join(work, "out-tree"), tree_cmds,
        lambda s, d: subprocess.run(["diff", "-r", s, d], capture_output=True).returncode == 0))

    noop = os.path.join(work, "noop.tl")
    with open(noop, "w") as fh:
        fh.write("fn main() { }\n")
    startup = [timed([tallow, "run", noop]) for _ in range(RUNS)]
    results["interpreter_startup_ms"] = {"runs": [round(x, 1) for x in startup],
                                         "median": round(statistics.median(startup), 1)}

    with open(OUT, "w") as fh:
        json.dump(results, fh, indent=2)
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
