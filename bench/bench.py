#!/usr/bin/env python3
"""Benchmark tallowx against cp and rsync on this machine.

Two datasets:
  A. one 256 MiB file          — bulk throughput
  B. 2,000 small files / 40 dirs — per-file and metadata cost

Every command copies into a freshly removed destination. Three runs each; the
median is reported. Integrity is checked once per tool, after the last run
(sha256 for A, recursive diff for B).
"""
import json
import os
import shutil
import statistics
import subprocess
import sys
import time

SCRATCH = "/root/.hermes/cache/scratch"
BENCH = os.path.join(SCRATCH, "bench")
TREE = os.path.join(BENCH, "tree", "src")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results.json")
TALLOWX = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tallowx.tl")
RUNS = 3


def timed(cmd):
    t0 = time.monotonic()
    p = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ms = (time.monotonic() - t0) * 1000.0
    if p.returncode not in (0,):
        raise RuntimeError(f"{' '.join(cmd)} exited {p.returncode}")
    return ms


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


def sha(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    tallow = shutil.which("tallow")
    if not tallow:
        sys.exit("tallow not on PATH")
    big_src = os.path.join(BENCH, "src.bin")
    if not os.path.exists(big_src):
        sys.exit("missing dataset A: " + big_src)
    if not os.path.isdir(TREE):
        sys.exit("missing dataset B: " + TREE)

    a_cmds = [
        ("cp -a", lambda s, d: ["cp", "-a", s, d]),
        ("rsync -a", lambda s, d: ["rsync", "-a", s, d]),
        ("tallowx (verify)", lambda s, d: [tallow, "run", TALLOWX, "--", "copy", s, d]),
        ("tallowx --no-verify", lambda s, d: [tallow, "run", TALLOWX, "--", "copy", s, d, "--no-verify"]),
    ]
    b_cmds = [
        ("cp -a", lambda s, d: ["cp", "-a", s, d]),
        ("rsync -a", lambda s, d: ["rsync", "-a", s + "/", d + "/"]),
        ("tallowx (verify)", lambda s, d: [tallow, "run", TALLOWX, "--", "copy", s, d]),
        ("tallowx --no-verify", lambda s, d: [tallow, "run", TALLOWX, "--", "copy", s, d, "--no-verify"]),
    ]

    results = {"engine": subprocess.run([tallow, "--version"], capture_output=True, text=True).stdout.strip(),
               "host": os.uname().machine, "runs": RUNS, "datasets": []}

    dst_a = os.path.join(BENCH, "out-a.bin")
    results["datasets"].append(bench(
        "A: single 256 MiB file", big_src, dst_a, a_cmds,
        lambda s, d: os.path.exists(d) and sha(s) == sha(d)))

    dst_b = os.path.join(BENCH, "out-tree")
    results["datasets"].append(bench(
        "B: 2,000 files / 40 dirs (9.9 MB)", TREE, dst_b, b_cmds,
        lambda s, d: subprocess.run(["diff", "-r", s, d], capture_output=True).returncode == 0))

    # interpreter startup cost, measured alone so the small-file numbers are readable
    noop = os.path.join(BENCH, "noop.tl")
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
