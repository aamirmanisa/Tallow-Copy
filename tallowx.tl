// tallowx — a verified copy/move CLI written in Tallow.
//
// Copies and moves files and directory trees on local filesystems and on
// network-mounted storage (NFS, SMB/CIFS, sshfs — anything mounted at a path).
// What it adds over `cp`/`rsync` in this environment:
//
//   * every copied file is verified by BLAKE3 hashing the bytes on disk —
//     the source is re-read and the destination is read back, so the check is
//     of what landed, not of a buffer the writer already had
//   * metadata preservation (mode + mtime) is reported per run, not assumed
//   * skip-if-identical, so a re-run is cheap
//   * honest metadata reporting per run (mode + mtime), and a note in
//     docs/DESIGN.md on which engine copy primitive is memory-bound
//   * one machine-readable summary line, and exit codes that mean something
//
// Usage (the tool runs on the Tallow interpreter; see DESIGN.md for why):
//   tallow run tallowx.tl -- copy   SRC DST [--no-verify] [--json]
//   tallow run tallowx.tl -- move   SRC DST [...]
//   tallow run tallowx.tl -- plan   SRC DST
//   tallow run tallowx.tl -- verify SRC DST
//
// Exit codes: 0 ok · 1 failure · 2 usage.

// ── argument helpers ────────────────────────────────────────────────────

fn has_flag(args: []String, name: String) -> bool {
    var found = false
    for a in args {
        if a == name {
            found = true
        }
    }
    found
}

/// Positional arguments, in order, with flags (`-…`) dropped.
/// Read `--flag N` (or `--flag=N`) as an integer, clamped to a sane range.
fn int_flag(args: []String, name: String, fallback: i64) -> i64 {
    var i = 0
    while i < args.len() {
        let a = args[i]
        if a == name && i + 1 < args.len() {
            let v = args[i + 1].to_int()
            if v < 1 { return 1 }
            if v > 32 { return 32 }
            return v
        }
        if a.starts_with(name + "=") {
            let v = a.split("=")[1].to_int()
            if v < 1 { return 1 }
            if v > 32 { return 32 }
            return v
        }
        i = i + 1
    }
    fallback
}

fn positional(args: []String) -> []String {
    var out = []
    for a in args {
        let flag = a.starts_with("-")
        if !flag {
            out = out.push(a)
        }
    }
    out
}

// ── path helpers ────────────────────────────────────────────────────────

fn basename(path: String) -> String {
    var last = ""
    for p in path.split("/") {
        if p != "" {
            last = p
        }
    }
    last
}

/// Parent directory, preserving whether the path was relative.
/// dirname("a/b.txt") = "a" · dirname("b.txt") = "." · dirname("/a/b.txt") = "/a".
fn dirname(path: String) -> String {
    let absolute = path.starts_with("/")
    let parts = path.split("/")
    var out = ""
    var i = 0
    while i + 1 < parts.len() {
        let p = parts[i]
        if !(i == 0 && p == "") {
            if out == "" {
                out = if absolute { "/" + p } else { p }
            } else {
                out = out + "/" + p
            }
        }
        i = i + 1
    }
    if out == "" {
        out = if absolute { "/" } else { "." }
    }
    out
}

/// mkdir -p; an existing directory is not an error.
fn mkdir_p(path: String) -> Result<()> {
    if path == "" || path == "/" {
        return Ok(())
    }
    let absolute = path.starts_with("/")
    var cur = ""
    var first = true
    for p in path.split("/") {
        if p != "" {
            if first && !absolute {
                cur = p
            } else {
                cur = cur + "/" + p
            }
            first = false
            let r = fs.mkdir(cur)
        }
    }
    if !fs.is_dir(path) {
        bail "cannot create directory: " + path
    }
    Ok(())
}

// ── enumeration ─────────────────────────────────────────────────────────

struct Walk {
    files: []String,
    dirs: []String,
}

/// Walk `root` and return paths relative to it. Symlinked directories are
/// followed (bounded by `depth`) because NAS trees use them; a symlink loop is
/// cut off rather than followed forever.
fn walk_root(root: String, rel: String, files: []String, dirs: []String, depth: i64) -> Result<Walk> {
    if depth > 32 {
        return Walk { files: files, dirs: dirs }
    }
    let dir = if rel == "" { root } else { root + "/" + rel }
    let entries = fs.list_dir(dir)?
    var f = files
    var d = dirs
    for e in entries {
        let child = if rel == "" { e } else { rel + "/" + e }
        let full = root + "/" + child
        if !fs.exists(full) {
            print("warn  dangling symlink, skipped: " + full)
        } else {
            let info = fs.stat(full)?
            if info.is_dir {
                d = d.push(child)
                let sub = walk_root(root, child, f, d, depth + 1)?
                f = sub.files
                d = sub.dirs
            } else {
                f = f.push(child)
            }
        }
    }
    Walk { files: f, dirs: d }
}

/// Resolve SRC to a base root plus relative file and directory paths.
struct Job {
    root: String,
    files: []String,
    dirs: []String,
}

fn enumerate(src: String) -> Result<Job> {
    let info = fs.stat(src)?
    if info.is_file {
        return Job { root: dirname(src), files: [basename(src)], dirs: [] }
    }
    if !info.is_dir {
        bail "not a regular file or directory: " + src
    }
    let walked = walk_root(src, "", [], [], 0)?
    Job { root: src, files: walked.files, dirs: walked.dirs }
}

// ── transfer ────────────────────────────────────────────────────────────

struct RunStats {
    copied: i64,
    skipped: i64,
    failed: i64,
    verified: i64,
    metadata_ok: i64,
    bytes: i64,
    elapsed_ms: i64,
}

fn mbps(bytes: i64, ms: i64) -> i64 {
    var rate = 0
    if ms > 0 {
        rate = (bytes / 1024) * 1000 / ms / 1024
    }
    rate
}

/// Copy one file, then verify by reading both sides back.
fn copy_one(src: String, dst: String, verify: bool) -> Result<bool> {
    mkdir_p(dirname(dst))?
    let r = FileCopy.copy_metadata(src, dst)
    if verify {
        let h_src = Transfer.hash(src)
        let h_dst = Transfer.hash(dst)
        if h_src != h_dst {
            bail "blake3 mismatch after copy: " + dst
        }
    }
    Ok(r.metadata_preserved)
}

fn add_stats(a: RunStats, b: RunStats) -> RunStats {
    RunStats {
        copied: a.copied + b.copied,
        skipped: a.skipped + b.skipped,
        failed: a.failed + b.failed,
        verified: a.verified + b.verified,
        metadata_ok: a.metadata_ok + b.metadata_ok,
        bytes: a.bytes + b.bytes,
        elapsed_ms: a.elapsed_ms + b.elapsed_ms,
    }
}

fn run(mode: String, src: String, dst: String, verify: bool, dry: bool, json: bool, workers: i64) -> Result<RunStats> {
    let job = enumerate(src)?
    let root = job.root
    let files = job.files
    let single = fs.is_file(src)

    var stats = RunStats { copied: 0, skipped: 0, failed: 0, verified: 0, metadata_ok: 0, bytes: 0, elapsed_ms: 0 }
    let t0 = time.monotonic()

    if !dry {
        for d in job.dirs {
            mkdir_p(dst + "/" + d)?
        }
    }

    // ── Parallel path ────────────────────────────────────────────────────
    // Each worker owns a contiguous slice and publishes counts to a stat file;
    // the parent sums them once every file appears. Sequential stays the
    // default because per-file ordering and per-file output are the contract.
    if !dry && workers > 1 {
        let total = files.len()
        let base = "/tmp/.tallowx-" + t0.to_string()
        var k = 0
        var cursor = 0
        while k < workers {
            let quota = total / workers
            var slice: []String = []
            var taken = 0
            while cursor < total && taken < quota {
                slice = slice.push(files[cursor])
                cursor = cursor + 1
                taken = taken + 1
            }
            if k == workers - 1 {
                while cursor < total {
                    slice = slice.push(files[cursor])
                    cursor = cursor + 1
                }
            }
            let stat_path = base + "-" + k.to_string() + ".stat"
            let h = spawn worker_slice(slice, root, dst, single, src, verify, mode, stat_path)
            k = k + 1
        }

        // Wait for completion. There is no joinable handle value in the
        // interpreter, so completion is observed through the stat files.
        var done = 0
        let deadline = time.monotonic() + 3600000000000
        while done < workers && time.monotonic() < deadline {
            done = 0
            var j = 0
            while j < workers {
                if fs.exists(base + "-" + j.to_string() + ".stat") {
                    done = done + 1
                }
                j = j + 1
            }
        }

        var j2 = 0
        while j2 < workers {
            let stat_path = base + "-" + j2.to_string() + ".stat"
            if fs.exists(stat_path) {
                stats = add_stats(stats, read_worker_stats(stat_path))
                fs.delete(stat_path)
            } else {
                stats.failed = stats.failed + 1
                if !json {
                    print("FAIL  worker " + j2.to_string() + " never reported (timeout)")
                }
            }
            j2 = j2 + 1
        }

        let tp = time.monotonic()
        stats.elapsed_ms = (tp - t0) / 1000000
        return Ok(stats)
    }

    for rel in files {
        let from = if single { src } else { root + "/" + rel }
        let to = if single { dst } else { dst + "/" + rel }

        var already = false
        if fs.exists(to) && fs.is_file(to) {
            let a = fs.stat(from)?
            let b = fs.stat(to)?
            if a.size == b.size && a.modified_at == b.modified_at {
                already = true
            }
        }

        if already {
            stats.skipped = stats.skipped + 1
            if !json {
                print("skip  " + from)
            }
        } else {
            if !fs.exists(from) {
                stats.skipped = stats.skipped + 1
                if !json {
                    print("skip  dangling or vanished: " + from)
                }
            } else {
            if dry {
                let a = fs.stat(from)?
                stats.bytes = stats.bytes + a.size
                if !json {
                    print("plan  " + from + " -> " + to)
                }
            } else {
                let outcome = copy_one(from, to, verify)
                match outcome {
                    Ok(meta) -> {
                        let a = fs.stat(from)?
                        stats.copied = stats.copied + 1
                        stats.bytes = stats.bytes + a.size
                        if meta {
                            stats.metadata_ok = stats.metadata_ok + 1
                        }
                        if verify {
                            stats.verified = stats.verified + 1
                        }
                        if !json {
                            print("copy  " + from + " -> " + to)
                        }
                        if mode == "move" {
                            let gone = fs.delete(from)
                            match gone {
                                Ok(_) -> stats.skipped = stats.skipped + 0
                                Err(e) -> {
                                    stats.failed = stats.failed + 1
                                    if !json {
                                        print("FAIL  cannot remove source " + from + ": " + e)
                                    }
                                }
                            }
                        }
                    }
                    Err(e) -> {
                        stats.failed = stats.failed + 1
                        if !json {
                            print("FAIL  " + from + ": " + e)
                        }
                    }
                }
            }
            }
        }
    }

    let t1 = time.monotonic()
    stats.elapsed_ms = (t1 - t0) / 1000000
    Ok(stats)
}

/// One worker: copy a contiguous slice of the file list and publish its counts.
///
/// The interpreter cannot return a value through a spawn handle (`await` on a
/// non-task operand is a synchronous pass-through and yields 0), so the counts
/// are written to a stat file the parent reads back. That is the only channel
/// that works on both engines today.
fn worker_slice(
    slice: []String,
    root: String,
    dst: String,
    single: bool,
    src: String,
    verify: bool,
    mode: String,
    stat_path: String,
) -> i64 {
    var copied = 0
    var skipped = 0
    var failed = 0
    var verified = 0
    var meta_ok = 0
    var bytes = 0

    for rel in slice {
        let from = if single { src } else { root + "/" + rel }
        let to = if single { dst } else { dst + "/" + rel }

        var already = false
        if fs.exists(to) && fs.is_file(to) {
            let a = fs.stat(from)?
            let b = fs.stat(to)?
            if a.size == b.size && a.modified_at == b.modified_at {
                already = true
            }
        }

        if already || !fs.exists(from) {
            skipped = skipped + 1
        } else {
            match copy_one(from, to, verify) {
                Ok(meta) -> {
                    let a = fs.stat(from)?
                    copied = copied + 1
                    bytes = bytes + a.size
                    if meta { meta_ok = meta_ok + 1 }
                    if verify { verified = verified + 1 }
                    if mode == "move" {
                        fs.delete(from)
                    }
                }
                Err(e) -> {
                    failed = failed + 1
                }
            }
        }
    }

    fs.write_file(
        stat_path,
        copied.to_string() + " " + skipped.to_string() + " " + failed.to_string() + " "
            + verified.to_string() + " " + meta_ok.to_string() + " " + bytes.to_string(),
    )
    return copied
}

/// Read one worker's stat file back into counters.
fn read_worker_stats(path: String) -> RunStats {
    let parts = fs.read_file(path).split(" ")
    RunStats {
        copied: parts[0].to_int(),
        skipped: parts[1].to_int(),
        failed: parts[2].to_int(),
        verified: parts[3].to_int(),
        metadata_ok: parts[4].to_int(),
        bytes: parts[5].to_int(),
        elapsed_ms: 0,
    }
}

fn verify_tree(src: String, dst: String) -> Result<i64> {
    let job = enumerate(src)?
    let root = job.root
    let files = job.files
    let single = fs.is_file(src)
    var bad = 0
    for rel in files {
        let from = if single { src } else { root + "/" + rel }
        let to = if single { dst } else { dst + "/" + rel }
        if !fs.exists(to) {
            print("missing  " + to)
            bad = bad + 1
        } else {
            let h1 = Transfer.hash(from)
            let h2 = Transfer.hash(to)
            if h1 != h2 {
                print("mismatch " + to)
                bad = bad + 1
            }
        }
    }
    Ok(bad)
}

fn usage() {
    print("tallowx — verified copy/move for local and mounted storage")
    print("")
    print("  tallowx plan   SRC DST")
    print("  tallowx copy   SRC DST [--no-verify] [--json] [--workers N]")
    print("  tallowx move   SRC DST [--no-verify] [--json]")
    print("  tallowx verify SRC DST")
    print("")
    print("  --no-verify  skip BLAKE3 read-back verification (faster; verifies nothing)")
    print("  --json       one machine-readable summary line")
    print("  --workers N  copy N slices concurrently via spawn (default 1)")
    print("               results are passed through per-worker stat files: the")
    print("               interpreter's await on a spawn handle returns 0, so a")
    print("               return value cannot be used to collect counts")
}

fn main() {
    let argv = env.args()
    if argv.len() == 0 {
        usage()
        process.exit(2)
    }
    let cmd = argv[0]
    if cmd == "help" || cmd == "--help" || cmd == "-h" {
        usage()
        process.exit(0)
    }

    let pos = positional(argv)
    if pos.len() < 3 {
        usage()
        process.exit(2)
    }
    let src = pos[1]
    let dst = pos[2]
    let verify = !has_flag(argv, "--no-verify")
    let json = has_flag(argv, "--json")
    let workers = int_flag(argv, "--workers", 1)

    if cmd == "verify" {
        let outcome = verify_tree(src, dst)
        match outcome {
            Ok(n) -> {
                if n == 0 {
                    print("verify ok - every file matches by BLAKE3")
                    process.exit(0)
                } else {
                    print("verify failed - " + n.to_string() + " file(s) differ")
                    process.exit(1)
                }
            }
            Err(e) -> {
                print("verify error: " + e)
                process.exit(1)
            }
        }
    }

    if cmd != "copy" && cmd != "move" && cmd != "plan" {
        usage()
        process.exit(2)
    }

    let outcome = run(cmd, src, dst, verify, cmd == "plan", json, workers)
    match outcome {
        Ok(stats) -> {
            if json {
                print('{"command":"' + cmd + '","copied":' + stats.copied.to_string() + ',"skipped":' + stats.skipped.to_string() + ',"failed":' + stats.failed.to_string() + ',"verified":' + stats.verified.to_string() + ',"metadata_preserved":' + stats.metadata_ok.to_string() + ',"bytes":' + stats.bytes.to_string() + ',"elapsed_ms":' + stats.elapsed_ms.to_string() + ',"mbps":' + mbps(stats.bytes, stats.elapsed_ms).to_string() + '}')
            } else {
                print("")
                print(cmd + ": " + stats.copied.to_string() + " file(s), " + stats.bytes.to_string() + " bytes, " + stats.elapsed_ms.to_string() + " ms")
                print("  verified: " + stats.verified.to_string() + " | metadata preserved: " + stats.metadata_ok.to_string() + " | skipped: " + stats.skipped.to_string() + " | failed: " + stats.failed.to_string())
                print("  throughput: " + mbps(stats.bytes, stats.elapsed_ms).to_string() + " MiB/s")
            }
            if stats.failed > 0 {
                process.exit(1)
            }
            process.exit(0)
        }
        Err(e) -> {
            print("error: " + e)
            process.exit(1)
        }
    }
}
