# tallowx

**A verified copy/move tool for local disks and mounted NAS storage, written in
[Tallow](https://github.com/aamirmanisa/Tallow-Language).**

`tallowx` copies a file or a whole tree, then proves the copy by hashing the
bytes that actually landed on disk. It reports whether mode and mtime survived,
skips files that are already identical, and prints one machine-readable summary
line. It runs wherever the Tallow engine runs.

It does **not** claim a speed win over `cp` or `rsync`. Measured here, it is at
parity with `cp` for bulk data and slower for many small files. The reason to use
it is the evidence it leaves behind, not the stopwatch. Numbers below.

```console
$ ./tallowx copy /mnt/nas/photos /mnt/backup/photos
copy  /mnt/nas/photos/readme.txt -> /mnt/backup/photos/readme.txt
copy  /mnt/nas/photos/2024/img_0003.jpg -> /mnt/backup/photos/2024/img_0003.jpg
copy  /mnt/nas/photos/2024/img_0001.jpg -> /mnt/backup/photos/2024/img_0001.jpg
copy  /mnt/nas/photos/2024/img_0002.jpg -> /mnt/backup/photos/2024/img_0002.jpg

copy: 4 file(s), 6600006 bytes, 22 ms
  verified: 4 | metadata preserved: 4 | skipped: 0 | failed: 0
  throughput: 286 MiB/s
```

## Status

| | |
|---|---|
| Version | 0.1.0 |
| Engine | Tallow 1.5.2 (interpreter plane) |
| Platforms | wherever `tallow` runs — measured on linux-aarch64 |
| Tests | 11/11 smoke checks pass (`tests/smoke.sh`) |
| Licence | MIT |

## Install

You need the Tallow engine (`tallow` on `PATH`) and the libraries it links
against. On Debian/Ubuntu:

```console
$ sudo apt-get install -y clang liblzma-dev libbz2-dev
$ curl -fsSL https://raw.githubusercontent.com/aamirmanisa/tallowsphere/main/install.sh | bash
```

On Arch/CachyOS: `sudo pacman -S clang xz bzip2`, then the same installer.
`clang` is a **run-time** dependency, not just a build-time one — the engine
shells out to it for every program it compiles, including its own install
probe. Without `liblzma`/`libbz2` the probe fails to link and the installer
exits non-zero (found the hard way in this repo's CI).

Then:

```console
$ git clone <this repo> tallowx && cd tallowx
$ ./tallowx --help
```

or run it directly:

```console
$ tallow run tallowx.tl -- copy SRC DST
```

## Usage

```
tallowx plan   SRC DST                  # what would be copied; writes nothing
tallowx copy   SRC DST [--no-verify] [--json]
tallowx move   SRC DST [--no-verify] [--json]
tallowx verify SRC DST                  # re-check an existing destination
```

- `--no-verify` skips the BLAKE3 read-back. It is faster and proves nothing.
- `--json` prints a single summary object and suppresses per-file lines.
- Exit codes: `0` ok, `1` failure or verification mismatch, `2` usage.

`SRC` may be a file or a directory. `DST` may be a path on any mounted
filesystem — ext4, XFS, btrfs, ZFS, NFS, SMB/CIFS, sshfs. Nothing in the tool
is local-filesystem specific; it uses the kernel's copy path and the mounted
path you give it.

### Output

Two stderr lines are expected on every run and are not errors:

```
warning[W0102]: use of possibly undefined variable `FileCopy`   ← checker false positive
* native build unavailable … running in the interpreter          ← engine plane marker
```

The first is a type-checker false positive for a namespace that resolves at run
time (ENGINE-FINDINGS #2-adjacent); the second is the engine stating which
execution plane it used, which it never suppresses. Redirect stderr if you want
clean logs: `./tallowx copy a b 2>/dev/null`.

### What is guaranteed

- **Integrity.** With verification on (the default), every copied file is
  hashed twice from disk — source and destination — with BLAKE3 and compared.
  A mismatch fails the file and the run exits `1`.
- **Metadata.** Mode bits and mtime are preserved by the copy primitive and
  counted; the summary reports how many files kept them.
- **No silent short writes.** A file that cannot be copied fails loudly; the
  run does not report success with a missing file.

### What is not guaranteed

- **Symlinks are dereferenced, not preserved.** A link becomes a copy of its
  target. Dangling links are reported and skipped.
- **Ownership (uid/gid) and xattrs/ACLs are not preserved.** The run is done as
  the invoking user; `--preserve=all` semantics are out of scope for 0.1.
- **No resume after interruption.** Re-running skips files whose size and mtime
  already match, which approximates resume at file granularity, not byte level.
- **A hard I/O error aborts the run.** The engine's copy primitive returns a
  value, not a `Result`, so a failure surfaces as a runtime error; the tool
  cannot catch it and continue with the rest of the tree. Missing or dangling
  sources are screened out before the call.

## Benchmarks

Median of 3 runs per tool, same machine, destination removed between runs,
integrity checked after the last run. Engine `tallow 1.5.2`, linux-aarch64,
ext4. Raw data in [`bench/results.json`](bench/results.json);
reproduce with `python3 bench/bench.py`.

**A — one 256 MiB file**

| Tool | Median | vs `cp` |
|---|---|---|
| `cp -a` | 168.0 ms | 1.00× |
| `rsync -a` | 507.7 ms | 3.02× slower |
| `tallowx` (verify) | 721.7 ms | 4.30× slower |
| `tallowx --no-verify` | 179.4 ms | 1.07× slower |

**B — 2,000 files in 40 directories**

| Tool | Median | Notes |
|---|---|---|
| `cp -a` | 76.8 ms | |
| `rsync -a` | 167.8 ms | |
| `tallowx` (verify) | 594.8 ms | includes ~286 ms interpreter startup |
| `tallowx --no-verify` | 529.4 ms | ~245 ms of work |

Reading these numbers:

- Bulk copy is **at parity with `cp`** because both end up in the kernel's copy
  path (`copy_file_range` / sendfile through `std::fs::copy`). There is no
  userspace fast path to win here.
- Verification costs roughly **3–4× the copy time on a large file** — it is
  three reads and one write instead of one read and one write.
- Many small files are dominated by **~286 ms of interpreter startup** plus a
  per-file interpreter dispatch. `tallowx` is ~7–8× slower than `cp` on that
  shape. If you copy thousands of tiny files and do not need verification, use
  `cp -a`.
- A 10,000-file tree (100 dirs, 512 B each) copied and diffed identical in
  1.6 s of tool time / 5.5 s wall, peak RSS 30 MB.
- Run-to-run variance on this host was 168–230 ms for `cp -a` on dataset A
  while page cache warmed; treat single-digit percentages as noise.

## Why it is interpreter-executed

The engine cannot compile this program to a native binary: the native backend
has no lowering for the primitives it needs (`FileCopy.copy_metadata`,
`fs.stat`, `fs.list_dir`, `fs.copy`, `process.spawn`, `time.monotonic`). Only
`Transfer.hash` and `Transfer.chunk` lower natively today. Every build attempt
fails with `native backend has no lowering for method …`, and the engine then
falls back to the interpreter at run time.

That is a property of engine 1.5.2, not of this tool. See
[`docs/ENGINE-FINDINGS.md`](docs/ENGINE-FINDINGS.md) for the ten findings behind
this design, each with a reproduction command, and
[`docs/DESIGN.md`](docs/DESIGN.md) for the architecture and the path to a
native build.

## Repository

```
tallowx.tl          the tool — one Tallow program, ~380 lines
tallowx             launcher (exec tallow run …)
tests/smoke.sh      11 end-to-end checks
bench/bench.py      benchmark harness → bench/results.json
docs/DESIGN.md      architecture and decisions
docs/ENGINE-FINDINGS.md  engine defects and gaps found while building this
docs/PRIOR-ART.md   what other transfer tools do, and what was deliberately not researched
```

## Prior art and scope

`tallowx` sits next to tools that already solve parts of this problem:
`cp --reflink`, `rsync`, `rclone`, `bbcp`, `fpart`/`GNU parallel`, `tar`+pipe,
and the content-addressed end of the field (`magic-wormhole`, `croc`,
`Syncthing`, `NNCP`). [`docs/PRIOR-ART.md`](docs/PRIOR-ART.md) records what each
one is good at and what was taken from it.

This project did **not** research intrusion techniques, exfiltration tradecraft,
or material from closed criminal forums. The requirement that motivated it is
plain: move bytes to a NAS and be able to prove afterwards that the bytes
arrived unchanged.

## Licence

MIT — see [`LICENSE`](LICENSE).
