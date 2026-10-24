# Design

## Shape

One Tallow program (`tallowx.tl`) plus a three-line launcher. No dependencies,
no build step, no state on disk.

```
argv ──▶ parse (flags, positional)
          │
          ├─ plan   ──▶ enumerate ──▶ print intended copies, no writes
          ├─ copy   ──▶ enumerate ──▶ mkdirs ──▶ per file: copy + hash + compare ──▶ summary
          ├─ move   ──▶ same, then unlink each verified source
          └─ verify ──▶ enumerate ──▶ hash both sides, report mismatches
```

`enumerate` is a recursive walk that returns a struct — `Job { root, files,
dirs }` — because tuple field access does not parse (ENGINE-FINDINGS #7).
Directories are collected separately so empty directories survive a copy.

## The five decisions that matter

### 1. `FileCopy.copy_metadata`, not `copy.file`

The two copy surfaces in the engine are not interchangeable
(ENGINE-FINDINGS #8):

- `copy.file` reads the whole file into a `Vec<u8>`: 1.5 GiB file → 1.5 GiB RSS,
  7.86 s.
- `FileCopy.copy_metadata` goes through `std::fs::copy` (kernel copy path),
  then applies mtime and permissions: 1.5 GiB → 25 MB RSS, 1.46 s, with mode
  and mtime preserved and reported.

For a NAS workload the second is the only viable primitive. The tool is built
on it, and the summary's "metadata preserved" count comes from the engine's own
`CopyResult.metadata_preserved`.

### 2. Verification is a re-read, not a flag

The engine exposes a copy path that computes a destination hash from the source
buffer it already holds (ENGINE-FINDINGS #10), so "verified" there is a
constant. `tallowx` ignores it and hashes both files from disk with
`Transfer.hash` (BLAKE3). That is the entire reason verification costs 3–4× a
bare copy, and it is a cost worth paying: a copy tool that cannot detect a bad
write is a copy tool that lies.

`--no-verify` exists because sometimes the bytes are already trusted (a
re-copy of a local dir) and the 4× is not worth it. It is documented as proving
nothing, and the summary still reports what actually happened (`verified: 0`).

### 3. Skip-if-identical, at file granularity

Before copying, if the destination exists and `size` and `modified_at` both
match, the file is skipped. This makes re-runs cheap and gives a crude resume:
after an interrupted run, the next one only moves what is missing.

It is intentionally not content-based — hashing every destination file to decide
whether to copy it would cost more than copying. The trade-off is that a file
whose content changed without a size or mtime change is not detected. `verify`
is the tool for that question.

### 4. No worker pool

Tallow 1.5.2 has channels, mutexes, atomics and wait groups, and no way to
start a thread (ENGINE-FINDINGS #11). `process.spawn` has no native lowering
and its `Process.pid()` is unknown at run time, so a process-based pool cannot
be assembled either. The copy is therefore sequential per file.

The engine's own "adaptive parallelism" is dead code (ENGINE-FINDINGS #9), so
there is nothing to switch on. This is the largest gap between this tool and
what the brief asked for, and it is recorded as such rather than papered over
with an option that does nothing.

### 5. ASCII source, structs over tuples, single-quoted JSON

Three language-surface quirks shaped the source:

- `\"` and `\xHH` are rejected by the lexer despite the spec (ENGINE-FINDINGS
  #5) → JSON is emitted from single-quoted literal fragments.
- Non-ASCII in string literals is mangled (ENGINE-FINDINGS #6) → all literals
  are ASCII; `|` instead of `·` in summaries.
- Tuple field access does not parse (ENGINE-FINDINGS #7) → named structs.

## Failure behaviour

| Situation | Behaviour |
|---|---|
| Destination exists, identical | skipped, counted |
| Destination exists, differs | overwritten (last writer wins), counted as copied |
| Source is a dangling symlink | reported, skipped, run continues |
| Source vanished between walk and copy | reported, skipped, run continues |
| Copy I/O error | run aborts with exit 1 — the primitive returns a value, not a `Result`, so it cannot be caught (README, "not guaranteed") |
| Hash mismatch | file counted failed, run exits 1 |
| `move` and unlink fails | counted failed, run exits 1, source remains |

Exit codes follow the engine's own convention: `0` success, `1` failure or
policy refusal, `2` usage. A run that reports `failed: 0` and exits `0` means
every file it touched was copied and, unless `--no-verify`, read back and
matched.

## Testing

`tests/smoke.sh` builds a fixture with the shapes that break naive copiers —
nested dirs, an empty dir, three permission modes, pinned mtimes, a unicode
filename, a file larger than a page cache read — and asserts 11 properties by
running the tool: plan writes nothing; copy is byte-identical; empty dirs
survive; mode+mtime match; a second run is a no-op; a flipped byte is caught
with exit 1; single-file copy; move empties the source; relative paths work;
usage exits 2.

Nothing is asserted from reading the code. Every check is a command with an
exit status.

`bench/bench.py` produces `bench/results.json` and re-checks integrity after
each tool (`sha256` for the single file, `diff -r` for the tree), so a fast
number from a broken copy cannot enter the table.

## Roadmap to a native, parallel tool

In dependency order, all of it engine work in `tallowsphere`, none of it
possible in `.tl` alone:

1. **Lower the metadata surface** — `fs.stat`, `fs.list_dir`, `fs.copy`,
   `FileCopy.copy/copy_metadata` in codegen. Turns this program into a single
   native binary; removes the ~280 ms startup and most of the small-file gap.
2. **A thread/worker primitive** in `sync` (or lowering for `process.spawn`
   plus a working `Process` handle). Unlocks a worker pool over the file list.
3. **Chunked read/write handles** (`open`/`read_at`/`write_at`/`seek`) so a
   copy can stream with bounded memory and per-chunk digests — the shape
   needed for verified parallel chunk copy and byte-level resume.
4. **A copy API that returns `Result`** instead of aborting the interpreter,
   so one bad file does not end a 100k-file run.
5. **Ownership and xattr preservation** (`chown`, `setxattr`, `utimensat` with
   atime), which no current primitive exposes.

Until 1–3 land, `tallowx` is honest about being an interpreter tool that buys
verification rather than speed.
