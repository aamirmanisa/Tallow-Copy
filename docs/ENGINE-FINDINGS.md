# Engine findings

Every finding below was observed while building `tallowx` against **Tallow
1.5.2** (`tallow --version` → `1.5.2`, git `8887e39d65`, linux-aarch64). Each
one carries the command that reproduces it. None of these are guesses about
what the code "should" do: they are what the binary in this tree does.

Line numbers refer to `tallowsphere` at the revision that shipped 1.5.2.

---

## 1. The transfer surface does not compile

`tallow build` fails for every program that uses the primitives a file tool
needs. Only hashing and chunking lower natively.

```console
$ printf 'fn main() { let i = fs.stat("/tmp") }\n' > /tmp/p.tl
$ tallow build /tmp/p.tl
build failed: native backend has no lowering for method 'stat' …
$ tallow run /tmp/p.tl
* native build unavailable … running in the interpreter
```

Confirmed the same for `fs.list_dir`, `fs.copy`, `FileCopy.copy`,
`FileCopy.copy_metadata`, `process.spawn`, `time.monotonic`, `String.starts_with`.
`Transfer.hash` and `Transfer.chunk` **do** build.

**Consequence:** any tool built on these runs on the interpreter. That is why
`tallowx` is a Tallow program plus a one-line launcher, and why every startup
pays ~280 ms.

Reproduce: `tallow build` any file in `probes/` terms — or simply run
`./tallowx --help` and read the first stderr line.

---

## 2. `FileInfo` does not match its declaration

`stdlib/fs.tl` declares:

```tallow
struct FileInfo { path, size, is_file, is_dir, modified: u64, created: u64 }
```

`do_stat` (`src/stdlib/fs.rs:291`, field set at `:311`) returns
`size`, `modified_at`, `is_file`, `is_dir` — no `path`, no `modified`, no
`created`.

```console
$ tallow run -  # program printing fs.stat(path)
FileInfo { size: 268435456, modified_at: 1709528767, is_file: true, is_dir: false }
$ # reading .modified:
runtime error: type error: no field 'modified' on struct
```

**Consequence:** a program written against the spec is wrong at run time, and
the type checker does not catch it because the native struct is opaque.

---

## 3. A missing struct field reads as `0`, not an error

`FileCopy.copy` (`src/stdlib/transfer.rs:551`, `fast_copy`) returns a `CopyStats`
with three fields: `bytes_copied`, `elapsed_ms`, `throughput_mbps`.
`stdlib/transfer.tl:35` declares five, three of which carry defaults:

```tallow
struct CopyStats {
    files_copied: i64 = 0,
    dirs_created: i64 = 0,
    bytes_copied: i64,
    elapsed_ms: i64,
    throughput_mbps: f64 = 0.0,
}
```

Reading `stats.files_copied` after a `FileCopy.copy` prints `0` — the default —
even though the function never sets it.

**Consequence:** "0 files copied" is indistinguishable from "this field was
never populated". A tool must not report numbers from fields it did not set
itself; `tallowx` counts files in Tallow code instead.

---

## 4. `fs.delete_file` is declared but uncallable

`stdlib/fs.tl` declares `delete_file(path) -> Result<()>`; no dispatcher has an
arm for it.

```console
$ tallow run -   # program calling fs.delete_file(path)
runtime error: undefined function: fs.delete_file
```

`fs.delete(path)` works (`src/stdlib/fs.rs:43-46` lists `delete` as implemented
inline in `interp.rs`). `tallowx move` uses `fs.delete`.

---

## 5. String escapes: the spec promises, the lexer refuses

`Tallow-Language/spec/01-lexical.md:111` documents `\n \t \r \\ \" \0 \xHH`.

```console
$ printf 'fn main() { print("a\\"b") }\n' > /tmp/e.tl && tallow run /tmp/e.tl
error[1:23]: unexpected character: '\'
$ printf 'fn main() { print("\\x22") }\n' > /tmp/e2.tl && tallow run /tmp/e2.tl
error[1:20]: invalid escape: \x
```

Single-quoted strings **do** work and preserve `"` literally
(`print('{"k": 1}')` → `{"k": 1}`), which is how `tallowx --json` emits JSON.

---

## 6. Non-ASCII in source literals is mangled on output

```console
$ printf 'fn main() { print("a · b — c") }\n' > /tmp/u.tl && tallow run /tmp/u.tl
a Â· b â c
```

The same characters arriving as *data* (a filename read from the directory)
print correctly. So the file is read as UTF-8 and the literal path is
double-encoded somewhere in the lexer/string table.

**Consequence:** keep source strings ASCII; `tallowx` does, and its summary
uses `|` instead of `·`.

---

## 7. Tuple values exist, tuple field access does not

`(A, B)` is a declared type (`spec/03-types.md:34`) and a function may return
`Result<(String, []String)>`, but `pair.0` does not parse:

```console
error[170:21]: expected identifier, found '0'
```

**Workaround:** return a struct with named fields. `tallowx` uses `Job` and
`Walk` for this reason.

---

## 8. The `copy` module is memory-bound; `FileCopy` is not

Two copy surfaces behave completely differently on the same 1.5 GiB file:

| Call | Wall | Peak RSS |
|---|---|---|
| `copy.file(src, dst)` (`tallow.copy`) | 7.86 s | **1,593,168 KB (~1.52 GiB)** |
| `FileCopy.copy(src, dst)` | 2.45 s | 18,548 KB |
| `FileCopy.copy_metadata(src, dst)` | 1.46 s | 25,720 KB |
| `cp` | 2.19 s | 2,048 KB |

`copy_file_streaming` (`src/stdlib/copy.rs:63`) reads the entire source into a
`Vec<u8>` before writing. `fast_copy` and `copy_with_metadata` go through
`std::fs::copy`, which uses the kernel's copy path.

**Consequence:** a 20 GiB file through `copy.file` needs 20 GiB of RAM. Use
`FileCopy.*` for bulk data; `tallowx` does.

---

## 9. "Adaptive parallelism" in the copy engine is dead code

`adaptive_worker_count` (`src/stdlib/copy.rs:496`) computes a worker count from
file count and CPU count. Its only call sites are tests
(`src/stdlib/copy.rs:879-882`, `:953`). `copy_dir_recursive` iterates serially.

**Consequence:** directory copies are single-threaded regardless of the
configuration the docs describe. There is no knob to turn on.

---

## 10. The engine's own copy "verification" cannot fail

`src/stdlib/copy.rs:84` and `:93` hash **the same in-memory buffer** for both
sides:

```rust
src_hasher.update(&file_data);
…
dst_hasher.update(&file_data);       // not a read of the destination
let verified = source_hash == destination_hash;
```

That comparison is true by construction; it proves nothing about what reached
the disk. There is no read-back of the destination anywhere in that path.

**Consequence:** any tool that reports "verified" from this flag is reporting a
constant. `tallowx` re-hashes both files from disk with `Transfer.hash`
(BLAKE3) after the copy, which is why verification costs 3–4× the copy.

---

## 11. Concurrency DOES exist — but nothing copy-shaped can be compiled

The earlier version of this finding said "no way to start a thread". That was
wrong, and the error came from reading `stdlib/sync.tl` (channels, mutexes,
atomics, wait groups — no thread constructor) instead of the language's own
`spawn` expression. Corrected from measurement:

```console
$ cat probe_spawn2.tl
fn work(p: String) -> i64 { print("worked:" + p)  return 1 }
fn main() { let h = spawn work("/tmp/x")  print("spawned") }

$ tallow run probe_spawn2.tl --interpret
spawned
worked:/tmp/x
$ tallow build probe_spawn2.tl && ./probe_spawn2
spawned
worked:/tmp/x
```

`spawn f(args)` parses in both engines, runs the callee in both, and the native
backend maps it to real OS threads (`tallow_async_spawn`, a pthread/Win32 worker
with a bounded live-task pool — `TL_MAX_LIVE_TASKS 4096` and a condition
variable for back-pressure). `async fn` + `.await` is the second form; the
interpreter treats `await` on a *non-task* operand as a synchronous
pass-through, and says so once at run time.

Two real concurrency measurements (512 MiB BLAKE3, 8-core aarch64 host, debug
build, so absolute numbers are slow but the ratio is the point):

| Program | native | interpreter |
|---|---|---|
| one `spawn` of the hash | 9.52 s | 9.08 s |
| two `spawn`s of the same hash | 9.38 s | 9.73 s |

Two hashes in the same wall time as one: both engines run spawned work
concurrently. A worker pool is therefore *expressible* today.

**What is actually missing** is the ability to compile a copy job that uses it:

```console
$ tallow build probe_async.tl
build failed: native backend has no lowering for method 'copy' at byte offset
45 on this receiver (unknown method for any statically-known kind);
failing loudly so the interpreter runs it
```

So the gap is not concurrency, it is the `fs`/`FileCopy` lowering surface. Once
`FileCopy.copy` and `fs.stat` lower, `spawn` gives real parallel copying for
free. Until then `tallow run --interpret` does run spawned work concurrently
(measured above), just at interpreter speed.

**Consequence:** parallelism is the cheap part; the lowering wave is the
expensive part. Scope work accordingly — and never claim a tool is
single-threaded-by-necessity without testing `spawn` first.
---

## What this costs a transfer tool

| Requirement | Status in 1.5.2 |
|---|---|
| Native binary | blocked (finding 1) |
| Async / parallel I/O | not expressible (finding 11) |
| Chunked copy with bounded memory | possible via `FileCopy`, not via `copy.*` (finding 8) |
| Metadata preservation | mode + mtime yes; ownership/xattrs no |
| Real integrity check | must be done by the caller from disk (finding 10) |
| Accurate progress numbers | caller must count (finding 3) |

`tallowx` is built to that table rather than around it.

## Addendum (2026-10-25): `tallowx` compiles natively — and is still wrong

After a lowering wave in `tallowsphere` (fs.mkdir, fs.list_dir, fs.stat,
FileCopy.copy_metadata, time.monotonic, `StringArray.push`, `[]String` loop
bindings, annotation/parameter struct types, `?` payload pointer recovery), the
whole program finally passes codegen and links:

```
$ tallow build tallowx.tl --release
built: tallowx
```

That is a *compile* result, not a working binary. Two array defects remain, both
visible in a ten-line program:

```
$ ./ap copy /tmp/nat-src /tmp/nat-dst     # writes argv.len, pos.len, pos[0]
argv.len=3
pos.len=1
pos[0]=217040051319584
```

1. **`[]String` returned from a function loses its kind.** `fn positional(args:
   []String) -> []String` returns a native array; the caller has no result kind
   for it, so `pos[i]` loads the element as an i64 (an address) instead of
   inttoptr-ing it. Function return types need to feed `method_result_kind` the
   same way module calls now do.
2. **`out = out.push(a)` inside a loop does not accumulate.** Three pushes leave
   `len == 1`. Either the reassignment rebinds a stale array pointer or `push`
   copies from the pre-push length.

Until those two are fixed, the interpreter remains the only correct plane and
`./tallowx` deliberately keeps running there. The non-verifying path of a
540 MB release binary that miscounts its own file list is not a shippable
artifact, and printing a speed number from it would be measuring the wrong thing.

Other traps this wave established, worth knowing before the next attempt:

- `match r { Ok(_) => .., Err(e) => .. }` does not register `e` as a variable on
  the native plane; the ident is emitted as an undefined global `@tallow.e` and
  clang fails. `if let Err(e) = r` does bind it (as a string pointer).
- The native `fs.delete` fails loudly instead of returning `Err`, so a `Result`
  binding around it cannot work; verify by observing `fs.exists` after the call.
- `let x = f()` where `f` returns `Result<Struct>` loses the struct type; an
  explicit `let x: Struct = f()?` is required for field reads.
- `match` arm bindings of Ok payloads are untyped for the same reason.
- The engine writes its output next to the source with the source's stem, so
  building `tallowx.tl` in the repo root overwrites the `tallowx` launcher
  script. Build in `build/`.
