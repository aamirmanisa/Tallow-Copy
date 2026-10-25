# Optimization report — tallowx and the Tallow engine

**Subject:** `tallowx` 0.1.0 (published as [Tallow-Copy](https://github.com/aamirmanisa/Tallow-Copy))
and the engine it runs on, `tallowsphere` 1.5.2.
**Method:** every number below comes from a command run on this host
(linux-aarch64, ext4, 8 cores, 16 GB RAM) against the installed engine
`tallow 1.5.2` (git `8887e39d65`). Where the host was busy, the load average is
recorded next to the number. Nothing is estimated except where it says
"expectation".

---

## Scope

Domains 1–4 of the brief asked for intelligence-agency operational methods,
private-military OPSEC, national cyber architectures, and blackhat/DEFCON
exploit technique. Those were **excluded**, as in the previous round: they are
not inputs to a file-copying tool, and turning them into a report is not
something this project will do. The public equivalents that actually inform
performance engineering — kernel I/O primitives, published systems papers,
vendor documentation, open-source competitor internals — were used instead and
are cited in `docs/PRIOR-ART.md`.

Domains 5–9 are covered: competitors, transfer platforms, emerging technology,
language choice, and a full audit of the Tallow surface.

---

## 1 · Measured baseline

### Process floor and start-up (median of 7)

| What | Time |
|---|---|
| `tallow --version` | 10.6 ms |
| `tallow run` on a trivial program | **303.2 ms** |
| `tallow run --interpret` on the same program | **29.2 ms** |
| native binary built from the same program | **4.4 ms** |
| `cp` of a 1 KB file | 2.2 ms |

The 303 ms is the `tallow run` front end — parse, type-check, contract
verification, and an attempted native lowering that is abandoned when the
program uses a primitive the backend cannot lower. It is **not** interpreter
initialisation: skipping the attempt with `--interpret` costs 29 ms.

This matters because `tallowx` cannot build natively (see §2), so every
invocation pays the attempt.

### Copy time (3 runs, median; `bench/results.json`, load not recorded)

| Dataset | `cp -a` | `rsync -a` | `tallowx` verify | `tallowx --no-verify` |
|---|---|---|---|---|
| 256 MiB single file | 168.0 ms | 507.7 ms | 721.7 ms | 179.4 ms |
| 2,000 files / 40 dirs | 76.8 ms | 167.8 ms | 594.8 ms | 529.4 ms |

### Contention check (load 4.1, 5 runs round-robin, minimum)

| Dataset | `cp -a` | `rsync -a` | `tar \| tar` | `tallowx` verify | `tallowx` no-verify |
|---|---|---|---|---|---|
| 256 MiB single file | 177.0 | 514.2 | — | 777.6 | 199.7 |
| 10,000-file tree | 359.5 | 476.6 | **265.7** | 5,049.2 | 5,011.2 |

The ordering is stable across both runs; the absolute numbers are not. Two
conclusions survive either condition:

1. **Bulk copy is at parity with `cp`** — both end in the kernel copy path.
2. **Per-file overhead is the gap.** 10,000 files cost `tallowx` ~4.7 s beyond
   start-up (0.47 ms/file loaded; 0.11 ms/file measured on the 2,000-file tree
   when quiet) against `cp`'s 0.037 ms/file. That is 3–13× per file, and it is
   interpreter dispatch, not I/O.

### Hash and copy primitives

| Primitive | Measurement |
|---|---|
| BLAKE3 over 256 MiB, native binary | 404.5 ms (~664 MB/s) |
| BLAKE3 over 256 MiB, interpreter (`--interpret`) | 315.2 ms (~850 MB/s) |
| `FileCopy.copy` 1.5 GiB | 2.43 s, peak RSS 18.5 MB |
| `FileCopy.copy_metadata` 1.5 GiB | 1.46 s, peak RSS 25.7 MB, mode+mtime preserved |
| `copy.file` 1.5 GiB | **7.86 s, peak RSS 1.52 GiB** |
| `cp` 1.5 GiB | 2.19 s, peak RSS 2.0 MB |

Hashing is **not** the bottleneck; the interpreter's BLAKE3 measured at least
as fast as the native build's. Verification's 3–4× cost on a 256 MiB file is I/O (three reads,
one write), not CPU.

---

## 2 · What the engine actually provides

Source: `docs/ENGINE-FINDINGS.md` in the repo, ten findings with reproductions.
Summary of what constrains performance work:

| Capability | State in 1.5.2 |
|---|---|
| Native lowering of `Transfer.hash`, `Transfer.chunk` | yes |
| Native lowering of `fs.stat`, `fs.list_dir`, `fs.copy`, `fs.rename`, `FileCopy.*`, `copy.file` | **no** (`tallow build` fails) |
| Thread spawn / async at language level | **absent** (`sync` has channel/mutex/atomic/wait_group only) |
| `process.spawn` + `Process.pid()` | no lowering; `pid()` is an unknown method at runtime |
| Kernel copy path | yes (`copy_file_with_fallback` → `copy_file_range`/sendfile) |
| Chunked read/write handles (seek/read_at) | not exposed |
| Metadata: mode, mtime | yes |
| Metadata: uid/gid, xattrs, ACLs, atime | not exposed |
| Directory copy parallelism | **dead code** (`adaptive_worker_count` has test-only call sites) |
| Engine-reported copy verification | **constant true** (hashes one buffer twice) |

Two of these are correctness problems, not performance ones, and they bound what
a fast tool may claim: a copier that cannot detect a short write, and a
"verified" flag that cannot be false.

---

## 3 · Prioritised recommendations

Ordered by (impact ÷ effort). "Impact" is what the measurement above says it
buys; "effort" is engine work in `tallowsphere`.

### P0 — Native lowering for the filesystem surface

**Impact:** removes the 303 ms start-up path and the per-file interpreter
dispatch; enables a single native binary. On the 10,000-file dataset that is
the difference between 5.05 s and something bounded by I/O.
**Effort:** medium. **Where:** `src/codegen.rs` (lowering arms),
`src/stdlib/fs.rs`, `src/runtime/`.

The machinery already exists: `codegen.rs` declares 272 `@tallow_*` FFI symbols,
including `@tallow_copy_file`, `@tallow_fs_read_bytes`, `@tallow_fs_write_bytes`
and `@tallow_file_hash`. What is missing is the arm that maps the *language*
surface (`FileCopy.copy`, `fs.copy`, `fs.stat`, `fs.list_dir`) onto them.
`copy.file` fails with `no lowering for method 'file'` even though
`@tallow_copy_file` is declared — the symbol and the surface are not wired.

Strategy:

1. Add lowering for `fs.stat` first (one FFI returning a struct; unblocks every
   walk loop).
2. Then `fs.list_dir`, `fs.exists`, `fs.is_file`, `fs.is_dir`, `fs.rename`,
   `fs.delete`, `fs.mkdir`.
3. Then `FileCopy.copy` / `copy_metadata` / `fs.copy` → `@tallow_copy_file`.
4. Gate the whole thing with the existing parity harness: every new arm must
   produce byte-identical output on both planes, and the conformance suite must
   stay at 0 failures.

Acceptance: `tallow build tallowx.tl` exits 0, the binary passes `tests/smoke.sh`
unchanged, and `tallow run tallowx.tl -- copy a b` matches the binary's output.

### P0 — A worker primitive, then file-level parallelism

**Impact:** the only lever that scales with core count. A copy of 10,000 small
files is embarrassingly parallel; today it is serial.
**Effort:** medium. **Where:** a small `.tl` helper over the existing `spawn`
primitive. Correcting this report: `spawn f(args)` already runs the callee
concurrently in both engines, and the native backend maps it to pthreads with a
bounded live-task pool (`TL_MAX_LIVE_TASKS 4096`). Measured: two concurrent
512 MiB hashes took 9.38 s where one took 9.52 s. The missing piece is a
bounded queue with deterministic error aggregation, not a thread constructor.

Pick one and only one:

- **(a) `spawn(fn)` + `WaitGroup`.** Cleanest; needs the interpreter and codegen
  to model a thread and shared ownership.
- **(b) `process.spawn` + a real `Process` handle.** Cheaper to implement, but
  workers become processes with their own start-up cost; only pays off if
  start-up is fixed by the P0 above.

Then `tallowx` gains `--workers N` with a bounded queue over the file list.
Ordering rule that matters: on spinning disks, parallel writers lose; the
scheduler must cap in-flight writes per device (`/sys/block/*/queue/rotational`).

**Expectation, not measurement:** 2–4× on 4 workers for many small files on
NVMe; ≤1.2× for one large file (that needs the P1 chunk work). Do not ship the
flag before this is measured.

### P1 — Chunked handles: `open`/`read_at`/`write_at`/`seek`

**Impact:** four things at once — bounded memory for any file size, byte-level
resume, per-chunk digests, and parallel chunks within one file.
**Effort:** large. **Where:** new FFI in `src/runtime/`, lowering arms, four
methods on a `File` type in `stdlib/fs.tl`.

Design constraints learned from the measurements:

- `copy.file` currently reads the whole file into a `Vec<u8>` (1.52 GiB RSS for
  a 1.5 GiB file). Any new path must never do that; the API should make the
  whole-file read impossible, not merely discouraged.
- Chunk size must be a parameter with a documented default (256 KiB matches the
  engine's existing `Transfer.chunk` default) and a hard cap on in-flight
  chunks per worker.
- The resume index must be a Merkle root over chunk hashes — the engine already
  has `Transfer.tree_hash` and `Transfer.chunk`; reuse them so a resumed file
  is verified against the same root as a fresh copy.

### P1 — A copy that returns `Result`

**Impact:** turns one bad file into one failed file instead of an aborted run.
**Effort:** small-medium, but it is an API break across the stdlib.

Today `FileCopy.copy_metadata` returns `CopyResult`, so an EACCES on file 3 of
100,000 raises a runtime error and the run stops. `tallowx` screens existence
before calling, which covers dangling symlinks but not permissions, full
disks, or NFS `ESTALE`.

Strategy: add `try_copy`-shaped variants returning `Result<CopyResult>` and keep
the current names as unwrapping wrappers for one release. Then `tallowx` can
report a failure count instead of dying.

### P1 — Declaration honesty (three concrete drifts)

**Impact:** every program written against the spec is currently wrong at
runtime in ways the checker accepts. Cheap to fix, and it unblocks writing
tools without a probe step for each call.
**Effort:** small.

1. `FileInfo` declares `path/modified/created`; runtime returns
   `size/modified_at/is_file/is_dir` (`src/stdlib/fs.rs:291`). Align the
   declaration or add the fields.
2. `fs.delete_file` is declared with no dispatch arm; `fs.delete` works
   (`src/stdlib/fs.rs:43-46`). Delete the dead declaration.
3. `CopyStats.files_copied` defaults to `0` and `fast_copy` never sets it, so a
   caller reads a silent zero. Either set it or remove it — a field that can
   only lie should not exist.

Add one test: for every `native fn` declared in `stdlib/*.tl`, dispatch must
return `Some`, not `None`. That test would have caught (2) and the `file_size`
case already noted in the tree.

### P2 — Make `copy.dir` streaming and delete the dead "adaptive" path

`copy_file_streaming` (`src/stdlib/copy.rs:63`) reads the whole file;
`adaptive_worker_count` (`:496`) is referenced only from tests. Either implement
the worker pool it advertises or delete both and point users at `FileCopy.*`.
Shipping a documented "adaptive parallelism" that does not exist is worse than
having no such claim.

### P2 — Engine-side verification must read back, or be removed

`src/stdlib/copy.rs:84` and `:93` hash the same in-memory buffer for both sides,
so `verified` is true by construction. Either read the destination back (and
pay for it, honestly) or drop the flag and let callers verify. A boolean that
cannot be false is a defect with a friendly name.

### P3 — Metadata completeness and symlinks

Add `chown`, `utimensat` (atime + mtime), `setxattr`, and a `symlink`-preserving
copy mode. Until then `tallowx` documents that ownership, ACLs and xattrs are
not preserved and that symlinks are dereferenced — which is the honest position,
but it is a gap against `rsync -a` and `cp -a`.

---

## 4 · Competitive analysis

| Tool | Model | Where it beats tallowx today | Where tallowx is ahead |
|---|---|---|---|
| `cp -a` | one process, kernel copy | 3–13× faster per file; ownership hardlinks | read-back verification, summary |
| `rsync -a` | delta protocol, quick check | partial transfer, `--append-verify`, sparse, hardlinks, remote | verification of local bytes is end-to-end by default |
| `tar \| tar` | one stream, archive headers | **fastest on 10,000 small files here (265.7 ms vs cp 359.5)** | per-file reporting, resumability |
| `rclone` | multi-backend, parallel transfers | `--transfers/--checkers`, `--checksum`, server-side copy | one static binary, no config |
| `croc` / `magic-wormhole` | PAKE pairing over a relay | cross-machine transfer with a short code | local speed, no relay in the path |
| `Syncthing` | continuous sync, block hashes | resumable block sync, conflict handling | simplicity, no daemon |
| `bbcp` | multi-stream bulk over network | streams, checksums per stream | n/a (local tool) |
| `ZFS`/`btrfs` send | snapshot stream | snapshot consistency + checksums, far faster on trees | filesystem-agnostic |

What to copy from competitors, in order: (1) `tar`'s lesson that one sequential
stream beats per-file syscall storms — the engine's fix is a native loop, not a
smarter tool; (2) `rsync`'s partial-file resume, which needs the P1 chunk API;
(3) `rclone`'s parallel transfers, which need the P0 worker primitive;
(4) `rclone`'s post-copy verification as a product norm.

What not to build: a delta algorithm (rsync owns it, and it needs two-sided
state), cloud backends, and a sync daemon.

---

## 5 · Technology assessment

| Technology | Verdict for this tool |
|---|---|
| `copy_file_range` / `sendfile` | Already used; this is why bulk copy is at parity with `cp`. Must be *detected* on the target filesystem — it silently degrades on some NFS/CIFS mounts. |
| `io_uring` | Present behind the `io-uring-backend` feature in `src/stdlib/io_backend.rs`, with a thread-pool fallback. Only reachable from the `copy` module path. Worth enabling and measuring **on the actual NAS mount** before optimising anything else. |
| Reflink (`FICLONE`) | Same-filesystem btrfs/XFS copies become metadata operations. Cheap to add, large win, zero integrity risk. Detect and use automatically; fall back silently. |
| Post-quantum crypto | The engine already ships ML-KEM/ML-DSA and OPAQUE. Irrelevant to a local copy; decisive if a network lane is added — reuse, do not invent. |
| AI-driven optimization | **No.** Chunk size, queue depth and worker count are cheap heuristics over measurable signals (latency per file, device rotational flag, free RAM). A model adds latency, non-determinism and an unexplained failure mode to a tool whose value is provable behaviour. If adaptivity is wanted, use a controller with explicit bounds and log its decisions. |
| Edge computing | Irrelevant to local/NAS copying. Relevant only to a future remote lane. |
| Checksummed streams (`ZFS`/`btrfs` send) | The honest recommendation for snapshot-shaped work on those filesystems; a per-file copier cannot match it. |

---

## 6 · Language choice

| Layer | Choice | Why |
|---|---|---|
| Engine hot paths (copy, hash, chunk, net) | **Rust** — as today | No GC, `copy_file_range`, io_uring crate, `rayon`, and the browser backend already forces C++ (BoringSSL) |
| Engine alternatives | C++ (already a dependency), Zig (no mature io_uring/TLS ecosystem), Go (GC + cgo boundary, larger runtime), JVM (start-up) | None wins for a workload bounded by syscalls |
| Tool/orchestration (`tallowx`) | **Tallow** — as today | The logic is bookkeeping over I/O; the stdlib has the primitives; one file, no build |
| Where Tallow is the wrong tool | per-file hot loops, until the fs lowerings land | interpreter dispatch (~0.1–0.5 ms/file); `spawn` exists and is concurrent in both engines, but a copy job cannot be compiled today |

Rule of thumb that the measurements support: **hot loop in Rust, policy in
`.tl`.** Every time that rule was violated in this build, the cost was visible
(per-file dispatch; the interpreter round trip for hash-then-compare).

---

## 7 · Verification criteria

Each gate is a command with a threshold. A change that does not move its gate, or
moves another one backwards, does not ship.

**Measurement discipline (prerequisite for all gates)**

```console
$ cat /proc/loadavg        # require 1-minute load < 1.5, else wait
$ for i in 1 2 3 4 5; do …; done   # min + median of 5, round-robin between tools
```

**G1 — Integrity, positive and negative**

```console
$ ./tests/smoke.sh                                  # 12/12, includes: corrupt 1 byte → verify exits 1
$ python3 - <<'PY'                                  # truncate a destination and require detection
# extend smoke.sh: truncate dst by 1 byte, `tallowx verify` must exit 1
PY
```
Threshold: 100% detection of a single flipped byte and of a 1-byte truncation,
in both directions (source and destination damage).

**G2 — Latency floor**

| Metric | Now | Gate after P0 |
|---|---|---|
| CLI invocation, empty work | 303 ms | ≤ 50 ms |
| Per-file overhead | 0.11–0.47 ms | ≤ 0.05 ms |
| Native binary start | 4.4 ms | ≤ 10 ms |

**G3 — Throughput, same filesystem**

| Dataset | Gate |
|---|---|
| 256 MiB, verify off | ≥ 0.95 × `cp -a` |
| 256 MiB, verify on | ≤ 5 × `cp -a` (verification is 3 reads + 1 write; it cannot be free) |
| 10,000 small files | ≥ 0.9 × `cp -a` after P0+P1 (today: 0.07×) |
| NAS mount (NFS/SMB) | ≥ 0.8 × `rsync -a` measured on the real mount, not loopback |

**G4 — Memory ceiling**

```console
$ /usr/bin/time -v tallowx copy /big/8GiB.bin /nas/8GiB.bin
```
Threshold: peak RSS ≤ 64 MB independent of file size. Today `copy.file` would
need 8 GiB; `FileCopy.copy_metadata` already passes (25.7 MB for 1.5 GiB).

**G5 — Concurrency actually scales**

Threshold: 4 workers ≥ 2.5× one worker on a 1,000-file tree, and workers must
not exceed the device in-flight cap. If the number does not move, the flag does
not ship.

**G6 — Stability at scale**

```console
$ tallowx copy /tree-100k /nas/tree-100k && tallowx verify /tree-100k /nas/tree-100k
```
Threshold: 0 failed files, RSS ≤ 64 MB, file descriptors bounded (sample
`ls /proc/<pid>/fd | wc -l` during the run), and a SIGKILL mid-run followed by a
re-run completes with every file verified.

**G7 — No plane regression**

```console
$ python3 conformance/run.py --tallow $(command -v tallow)     # 0 failures
$ tallow check tallowx.tl && tallow build tallowx.tl           # after P0: both 0
```
Threshold: both planes byte-identical on the conformance suite; that is the
engine's own rule and it should gate every optimisation above.

---

## 8 · What I would not do

- **Chase `cp` on bulk copy.** Both are in the kernel; the remaining difference
  is start-up and per-file dispatch, which the P0 items fix.
- **Add a model to the scheduler.** Unexplainable behaviour in a tool whose
  selling point is proof.
- **Advertise parallelism before it exists.** The engine already has a
  documented "adaptive" copy that is dead code; repeating that mistake in the
  tool layer would be worse, because users would trust it.
- **Build a delta engine.** `rsync` has two decades of edge cases; the honest
  answer for mixed trees is to call it.

---

## Appendix — reproduction

```console
$ python3 bench/bench.py                 # dataset A/B, 3 runs, integrity-checked
$ cat bench/results.json                 # the numbers quoted in §1
$ tail -60 docs/ENGINE-FINDINGS.md       # the ten engine findings with commands
```

Host: `tallow 1.5.2` (git `8887e39d65`), linux-aarch64, ext4 on `/dev/sda1`,
8 cores, 16 GB RAM. Contention is reported per table. The first table was taken before the
`rustc` build started, with load unrecorded; the second records load 4.1 and
uses round-robin minimums. Micro-measurements taken while `rustc` was
compiling were discarded.
