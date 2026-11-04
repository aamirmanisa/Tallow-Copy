# tallowx performance analysis, 2026-11-04

## Premise correction

tallowx is not a protocol. It is a local file-copy CLI written in Tallow: no wire
format, no handshake, no round-trip to minimise. The objective "optimise the
tallowx protocol to minimise round-trip time" cannot be executed as written —
there are no round trips. What *can* be measured is the work it does per copy:
syscalls, hashing passes, interpreter overhead and startup.

"Fastest protocol globally" is likewise not verifiable against a local
`read`/`write` loop. "Fastest verified copy" is, and that is what this document
tests.

## Method

- **Verified vs verified.** `cp -a` and `rsync -a` do not read the bytes back, so
  comparing them to tallowx-with-verify measures the guarantee rather than the
  copy. Every row is labelled with whether it verifies.
- Medians of 3 runs, destination removed before each run.
- Integrity is not assumed: the earlier harness (`bench/bench.py`) checks every
  copy, and every row below produced byte-identical output.
- Host: Hetzner ARM, 4 vCPU, ext4, engine `tallow 1.5.8` (build 2026-10-26).

## Results — A: one 256 MiB file

| tool | verifies | median | vs fastest |
|---|---|---|---|
| `cp -a` | no | 194.8 ms | 1.00× |
| `cp -a` + `sha256sum` both | yes | 627.7 ms | 3.22× |
| `rsync -a --checksum` | yes | 629.4 ms | 3.23× |
| `rsync -a` | no | 602.9 ms | 3.10× |
| **tallowx (interpreter, verify)** | yes | **818.8 ms** | **4.20×** |

## Results — B: 2,000 small files / 40 directories

| tool | verifies | median | vs fastest |
|---|---|---|---|
| `cp -a` | no | 80.7 ms | 1.00× |
| `cp -a` + `sha256sum` trees | yes | ~154 ms | 1.91× |
| `rsync -a --checksum` | yes | ~191 ms | 2.37× |
| `rsync -a` | no | 162.4 ms | 2.01× |
| **tallowx (interpreter, verify)** | yes | **691.6 ms** | **8.57×** |

## Where the time goes

1. **Interpreter startup: ~156 ms per run** (median of 3) — 23% of the small-file
   case before a single byte moves.
2. **Per-file overhead: ~0.27 ms/file** in the interpreter, against ~0.04 ms for
   `cp`. This is why the small-file gap (8.6×) is far worse than the big-file gap
   (4.2×).
3. **Two full BLAKE3 passes** over the data (`Transfer.hash(src)` then
   `Transfer.hash(dst)` after the copy) — three reads and one write total, the
   same shape as `cp` + `sha256sum`. Single-threaded: `blake3 = "1.8"` without the
   `rayon` feature on a 4-core box.
4. **The copy primitive is already fast, though less so than a single warm run suggested.**
   `copy_file_with_fallback` calls `std::fs::copy`, which uses `copy_file_range(2)`
   on Linux. A first probe measured 185 ms for 256 MiB, and that number was
   quoted in an earlier draft as a 3× advantage over a userspace read/write loop.
   Steady-state repetition does not support it:

   ```
   rep1  copy_file_range + separate hash  269.6 ms | hash-inline copy 533.6 ms  (+264)
   rep2  copy_file_range + separate hash  602.3 ms | hash-inline copy 533.4 ms  ( -69)
   rep3  copy_file_range + separate hash  565.8 ms | hash-inline copy 456.8 ms  (-109)
   ```

   185 ms was a warm-cache single run. Under writeback pressure the two strategies
   are within noise on this filesystem. The copy primitive is not a 3× lever here.


So the deficit is **interpreter overhead, not algorithm**. tallowx's structure
(copy once, hash twice, compare) is the same as the best verified competitor.

## tallowx runs natively for the first time

With the element-kind fix in `codegen.rs` and `push` lowered, `scripts/build-native.sh`
produces a 113 MB binary (`tallowx 0.2.0`). Measured against the verified
competitors, medians of 3:

```
A: one 256 MiB file                     B: 2,000 small files
cp -a                 174.1 ms          cp -a                     79.8 ms
rsync -a --checksum   488.7 ms          rsync -a --checksum      166.9 ms
cp -a + sha256sum     566.3 ms          tallowx NATIVE (verify)  205.3 ms
tallowx NATIVE        976.9 ms          tallowx interpret       4954.0 ms
tallowx interpret    9368.6 ms
```

On 2,000 small files the native plane is **within 1.23× of `rsync --checksum`**
while also verifying both ends — the 15.5× interpreter gap is gone. (The
interpreter figures here come from a debug engine and are inflated; the
comparable release-engine baseline was 692 ms for the tree.)

On the single big file it is slower than `rsync --checksum`, and the reason was
found rather than assumed: `tallow_file_hash` on the native plane did

```rust
match std::fs::read(p) {
    Ok(data) => blake3::hash(&data),   // whole file into RAM, one core
```

— a full-file allocation followed by the single-threaded hasher. **The rayon fix
in this document's earlier section went to `src/stdlib/transfer.rs`, which is the
*interpreter* path. The shipping native plane has its own implementation in
`src/runtime/transfer_ffi.rs`, and it was untouched.** That is why the binary
built from a release runtime still hashed slower than a release interpreter: the
optimisation had been applied to the plane the product does not ship.

Corrected in the same change: stream in 1 MiB chunks with `update_rayon`.

## Where tallowx now stands, and the one gap left

Measured 2026-11-04, native binary, medians of 3:

| workload | tallowx native | best verified competitor | verdict |
|---|---|---|---|
| 256 MiB full copy (verified) | **539.1 ms** | `rsync --checksum` 615.3 ms | **12% faster** |
| 2,000 files full copy (verified) | 193.7 ms | `rsync --checksum` 172.5 ms | 12% slower |
| 2,000 files, 1 changed (verified) | **1 file / 4,296 B**, 1,999 skipped | `rsync --checksum` 1 file / 4,296 B | **identical** |
| 256 MiB, 1 MiB changed (existing destination) | **676 ms** | `rsync --no-whole-file` 1,016 ms | **tallowx 1.5× faster** |

**Correcting an earlier line in this document.** A previous revision said rsync
"wins by 256×" on the incremental case because it moves 1,048,576 bytes where
tallowx moves 268,435,456. That is true of *bytes on the wire* and false of
*time*, which is what a copy tool is judged on:

```
tallowx native (whole file):   653 / 676 / 869 ms
rsync --no-whole-file (delta): 980 / 1016 / 1042 ms
```

Rolling-checksum delta has to read both sides and checksum them before it moves
anything. On a local filesystem that costs more than the copy it avoids. Block
delta pays only when the bytes cross a link that is slower than the disk — which
is why `rsync` over ssh is the right tool and `tallowx` on a mounted path is not
the same problem.

## What the Tallow-Language spec already documents

Surveyed 2026-11-04 (`aamirmanisa/Tallow-Language`, spec/06-stdlib.md). The
`transfer` module is documented far beyond the surface this analysis used:

- `chunk(path, chunk_size = 262144)` → `[]ChunkInfo` — per-chunk BLAKE3, already
  native (`tallow_transfer_chunk`).
- `tree_hash` / `manifest` — binary Merkle root over chunk hashes.
- `scan` / `diff` — directory delta by path+hash (what makes the tree case work).
- `send` / `receive` / `status` — a `TransferSession` carrying a BLAKE3 chunk
  manifest, i.e. the base for a *remote* transfer mode.
- `reed-solomon` `encode`/`decode` — real erasure coding, for lossy links.
- `compress`/`decompress`, mmap I/O, resume, bandwidth limiting.

**Most of it does not apply to tallowx**, because tallowx copies between paths on
one machine: erasure coding and session manifests solve problems it does not have,
and block-level delta is measurably slower locally (above). The reusable pieces
are the Merkle manifest if a remote mode is ever added, and the packaging
directory (three-platform bundles) for distribution.



Tree incrementals are already at parity: both tools move exactly the changed file
and skip the rest. The engine's delta primitives are directory-level
(`delta_scan` → `delta_diff` by path+hash → `delta_apply`), which is exactly what
that case needs.

Within-file block delta is the one thing tallowx does not have, and on these
measurements it should **not** be built for local copies: `transfer.chunk` gives
the per-chunk BLAKE3 that would be needed, but the rsync comparison above shows
the technique loses to a plain copy on the same disk. It becomes worth building
only alongside a real remote mode, where the link is the constraint.


## How it got here: two blockers, in sequence

**1 (fixed): the link.** `tallow build` linked against a runtime archive that
predates two exports:

```
/usr/bin/ld: undefined reference to `tallow_env_args'
/usr/bin/ld: undefined reference to `tallow_no_match'
```

Both symbols exist in source (`src/runtime/env_ffi.rs:21`,
`src/runtime/diag_ffi.rs:17`), and no `libtallow.a` existed anywhere on the host.
Building `cargo build --release --lib` produces a 551 MB `libtallow.a`; placing it
beside the engine resolves the link completely — verified, the undefined-symbol
error is gone.

**2 (open): the compiler.** With the link fixed, the build advances to:

```
build failed: the native backend has no lowering for Array.push; run with --interpret
```

`Array.push` is the primitive tallowx is built on (6 call sites). The registry in
`src/array_methods.rs` marks it `native: false` with this note:

> Codegen has an arm for this name and it is wrong on this plane (the bound result
> printed a raw byte).

That arm is `emit_array_push` (`src/codegen.rs:20138`). It allocates
`(new_len + 1) * 8`, stores the length, memcpys the old elements and stores the new
one — then returns `LLValue::new(buf, LLType::I8Ptr)` with **no array-shape
metadata**, so the printer treats the result as a string and prints its first byte,
the length. That matches the recorded symptom exactly.

So: the shipping tallowx has never run on the native plane, and the blocker is a
compiler shape-tracking bug in exactly the primitive the program uses — not build
wiring, and not this host.

## Why CI did not catch any of it

`tests/native.sh`, the job whose stated purpose is "does the native binary behave
the same?", contains:

```bash
if ! "$TALLOW" build "$BUILD/tallowx.tl" --release >"$ROOT/build.log" 2>&1; then
    printf 'skipped  native build refused: %s\n' "$(grep -m1 -E 'build failed|no lowering' "$ROOT/build.log" | cut -c1-120)"
    exit 0
fi
```

A permanent refusal is indistinguishable from a clean skip, and it exits **0**. The
job has therefore been green while exercising nothing. A gate that exits success on
the most likely failure is not a gate.


## Ranked optimisations, with what actually happened to each

| # | change | expected gain | risk | status |
|---|---|---|---|---|
| 1 | Provide a matching `libtallow.a` so tallowx builds native; make the launcher use it | Removes 156 ms startup and the ~0.23 ms/file interpreter tax — the largest single effect, especially for trees | low — build wiring only | **partially done**: the archive is built and the link failure is fixed. A second blocker stands: `Array.push` has no correct native lowering, so tallowx still cannot be compiled. |
| 2 | Enable `blake3`'s `rayon` feature and hash in 1 MiB chunks with `update_rayon` | Two full passes over all data currently use 1 of 4 cores | low | **done and measured**: same binary, `RAYON_NUM_THREADS=1` 4.82–4.87 s vs `=4` 1.32–1.44 s on 256 MiB — **3.5×**. |
| 3 | Hash the source during the copy instead of re-reading it afterwards | Removes one full read pass | medium | **rejected on evidence**: steady-state `copy_file_range` and inline-hash copying are within noise here (see item 4 above); on the warm path inline hashing is 264 ms *worse*. Not shipped on a number that changes sign between reps. |
| 4 | Batch metadata work for small files | Attacks the 0.27 ms/file tax on top of item 1 | medium — needs a new primitive reachable from both planes | designed, not built: a `fs.stat_many(paths) -> [Stat]` native, wired in four places (stdlib `.tl` declaration, `transfer.rs` dispatch, `interp.rs` dispatch, runtime FFI + codegen declaration). The last two are mandatory or native builds fail to link, which is exactly the failure this analysis started from. |

### The push lowering, tested rather than assumed

`Array.push` is flagged `native: false` with the note "the bound result printed a
raw byte". Since BP22 later taught codegen to track array-returning results, the
flag looked like it might be stale, so it was flipped to `true` and the engine
rebuilt. A two-plane parity test on the shapes tallowx actually uses:

```
interp  : 3 / alpha / beta / gamma / 2 / 7 / 41 / 4 / n3
native  : 3 / 196****8636 / 196****8644 / 196****8652 / 2 / 7 / 41 / 4 / 196****9984
```

Integer pushes and every `len()` are correct; **pushed strings come back as raw
pointer values**, because the array's element shape is lost through `push`. The
refusal is accurate and the flip was reverted, with the re-test recorded in the
registry comment so the next person does not repeat it.

This is the real reason tallowx has never run natively: it is built on the one
array operation the native plane cannot lower correctly.

### Root cause, found after the flip failed

The defect is not in `emit_array_push`. Element kind for an array variable is
inferred from the **first element of the literal**:

```rust
if let ExprKind::Array(items) = &value.kind {
    self.variable_is_array.insert(name.clone(), true);
    if let Some(first) = items.first() {          // empty literal → None
        if self.expr_is_string_like(first) {
            self.variable_array_elem_is_ptr.insert(name.clone(), true);
        }
    }
```

tallowx declares `var out: []String = []` — an **empty** literal — so `items.first()`
is `None`, `variable_array_elem_is_ptr` is never set, and the `[]String` annotation
on the declaration is ignored for element kind. Every later `push`, index and
print then reads the slots as integers. That is exactly the observed behaviour:
`[]i64` correct, `[]String` printing addresses.

The fix is bounded and local: when the literal is empty, take the element kind
from the declared type annotation instead of giving up. Then `push` can be
lowered, and tallowx can be compiled.




Items 2–4 are engine-side. None of them require touching network hardware, and
none of them is a "protocol" change, because there is no protocol.

## What can and cannot be claimed

- **Can claim:** with items 1–3, tallowx should be at or near `cp`+`sha256sum`
  while offering a stronger guarantee (BLAKE3 over both ends, metadata report,
  resume, skip). That is a defensible "fastest *verified* copy" claim, measured
  on this host.
- **Cannot claim:** "fastest protocol globally". There is no protocol, no peer,
  and the ceiling is the kernel's copy primitive plus one mandatory verify pass.
  Any claim of global superiority needs a defined workload, a defined competitor
  set and a public harness — the numbers above are one host, one filesystem.

## Reproduce

```bash
python3 bench/bench.py                  # bulk + small files, cp vs rsync vs tallowx
python3 bench/delta_bench.py            # incremental update: rsync vs xdelta3 vs tallowx
NATIVE=build/tallowx python3 bench/verified_comparison.py   # the verified-vs-verified table
```
