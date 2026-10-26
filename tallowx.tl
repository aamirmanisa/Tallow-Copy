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
// Usage (the launcher prefers a native build and falls back to the interpreter):
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
fn positional(args: []String) -> []String {
    var out: []String = []
    var skip_next = false
    for a in args {
        if skip_next {
            skip_next = false
        } else {
            if a == "--exclude" {
                skip_next = true
            } else {
                let flag = a.starts_with("-")
                if !flag {
                    out = out.push(a)
                }
            }
        }
    }
    out
}

/// Every value that follows `name` on the command line (`--exclude a --exclude b`).
fn flag_values(args: []String, name: String) -> []String {
    var out: []String = []
    var i = 0
    for a in args {
        if a == name && i + 1 < args.len() {
            out = out.push(args[i + 1])
        }
        i = i + 1
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
                let sub: Walk = walk_root(root, child, f, d, depth + 1)?
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
    targets: []String,
    dirs: []String,
}

fn enumerate(src: String) -> Result<Job> {
    let info = fs.stat(src)?
    if info.is_file {
        return Job { root: dirname(src), targets: [basename(src)], dirs: [] }
    }
    if !info.is_dir {
        bail "not a regular file or directory: " + src
    }
    let walked: Walk = walk_root(src, "", [], [], 0)?
    Job { root: src, targets: walked.files, dirs: walked.dirs }
}

// ── mirror mode ─────────────────────────────────────────────────────────

struct PrunePlan {
    files: []String,
    dirs: []String,
}

fn trim_dir(path: String) -> String {
    var p = path
    var cut = true
    while cut && p.len() > 1 && p.ends_with("/") {
        p = p.slice(0, p.len() - 1)
        if !p.ends_with("/") {
            cut = false
        }
    }
    p
}

fn contains_path(list: []String, p: String) -> bool {
    var hit = false
    for x in list {
        if x == p {
            hit = true
        }
    }
    hit
}

/// `--exclude` patterns are deliberately dumb: an exact relative path, a
/// directory prefix, or a trailing `*` suffix match. Anything cleverer belongs
/// in a config file, and a pattern language I cannot test exhaustively is a
/// delete path I should not ship.
fn pattern_hits(rel: String, pattern: String) -> bool {
    if rel == pattern {
        return true
    }
    if rel.starts_with(pattern + "/") {
        return true
    }
    if pattern.starts_with("*") {
        let suffix = pattern.slice(1, pattern.len())
        if rel.ends_with(suffix) {
            return true
        }
    }
    false
}

fn excluded(rel: String, patterns: []String) -> bool {
    var hit = false
    for p in patterns {
        if pattern_hits(rel, p) {
            hit = true
        }
    }
    hit
}

/// What the destination has and the source does not (relative paths).
fn prune_plan(src_files: []String, src_dirs: []String, dst: String, patterns: []String) -> Result<PrunePlan> {
    let walked: Walk = walk_root(dst, "", [], [], 0)?
    var files: []String = []
    for f in walked.files {
        if !excluded(f, patterns) && !contains_path(src_files, f) {
            files = files.push(f)
        }
    }
    var dirs: []String = []
    for d in walked.dirs {
        if !excluded(d, patterns) && !contains_path(src_dirs, d) {
            dirs = dirs.push(d)
        }
    }
    PrunePlan { files: files, dirs: dirs }
}

/// Remove the extras. Files first, then directories — a directory is only
/// deleted once it is empty, so a directory that still holds kept files is left
/// alone instead of taking its contents with it.
fn apply_prune(dst: String, plan: PrunePlan, dry: bool) -> Result<i64> {
    var n = 0
    for f in plan.files {
        let full = dst + "/" + f
        if dry {
            print("prune   " + full)
        } else {
            fs.delete(full)?
            n = n + 1
        }
    }
    var pass = 0
    var progress = true
    while progress && pass < 64 {
        progress = false
        for d in plan.dirs {
            let full = dst + "/" + d
            if fs.is_dir(full) {
                let left = fs.list_dir(full)?
                if left.len() == 0 {
                    if dry {
                        print("prune   " + full)
                    } else {
                        fs.delete(full)?
                        n = n + 1
                    }
                    progress = true
                }
            }
        }
        pass = pass + 1
        if dry {
            progress = false
        }
    }
    Ok(n)
}

// ── transfer ────────────────────────────────────────────────────────────

/// What a single file's copy did. Field names are distinct from `CopyResult`'s
/// on purpose: a bare `x.metadata_preserved` is ambiguous between two known
/// structs, and a match arm only learns its payload type from the annotation.
struct CopyOutcome {
    meta_restored: bool,
    resumed_from: i64,
}

struct RunStats {
    copied: i64,
    deleted: i64,
    skipped: i64,
    failed: i64,
    verified: i64,
    metadata_ok: i64,
    resumed: i64,
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
/// Files at least this large are worth resuming: below it, hashing the prefix
/// costs more than re-copying the whole file.
const RESUME_MIN: i64 = 8388608

/// How many bytes of `dst` are a provable prefix of `src` (0 = none).
///
/// A partial destination is resumed only when its first N bytes hash the same as
/// the source's first N bytes. That check is the point: appending to a
/// mismatched file would produce a byte-wrong result that a size check alone
/// would call complete.
fn resumable_bytes(src: String, dst: String, size: i64) -> Result<i64> {
    if !fs.exists(dst) {
        return Ok(0)
    }
    let have = fs.stat(dst)?
    if have.is_dir || have.size <= 0 || have.size >= size {
        return Ok(0)
    }
    let a = Transfer.hash_prefix(src, have.size)
    let b = Transfer.hash_prefix(dst, have.size)
    if a == b { Ok(have.size) } else { Ok(0) }
}

/// Copy one file, then verify by reading both sides back.
fn copy_one(src: String, dst: String, verify: bool, allow_resume: bool) -> Result<CopyOutcome> {
    mkdir_p(dirname(dst))?
    let info = fs.stat(src)?
    var resumed: i64 = 0
    var kept_meta = false

    if allow_resume && info.size >= RESUME_MIN {
        let off = resumable_bytes(src, dst, info.size)?
        if off > 0 {
            // copy_range carries the source's mtime, so a resumed file is
            // indistinguishable from a whole-file copy on the next run.
            fs.copy_range(src, dst, off, info.size - off)
            resumed = off
            kept_meta = true
        }
    }

    if resumed == 0 {
        // Not resumable: replace a stale destination outright rather than
        // appending to it.
        if info.size >= RESUME_MIN && fs.exists(dst) {
            fs.delete(dst)
        }
        let r: CopyResult = FileCopy.copy_metadata(src, dst)
        kept_meta = r.metadata_preserved
    }

    if verify {
        let h_src = Transfer.hash(src)
        let h_dst = Transfer.hash(dst)
        if h_src != h_dst {
            bail "blake3 mismatch after copy: " + dst
        }
    }
    Ok(CopyOutcome { meta_restored: kept_meta, resumed_from: resumed })
}

fn add_stats(a: RunStats, b: RunStats) -> RunStats {
    RunStats {
        copied: a.copied + b.copied,
        deleted: a.deleted + b.deleted,
        skipped: a.skipped + b.skipped,
        failed: a.failed + b.failed,
        verified: a.verified + b.verified,
        metadata_ok: a.metadata_ok + b.metadata_ok,
        resumed: a.resumed + b.resumed,
        bytes: a.bytes + b.bytes,
        elapsed_ms: a.elapsed_ms + b.elapsed_ms,
    }
}

fn run(mode: String, src: String, dst: String, verify: bool, dry: bool, json: bool, allow_resume: bool, checksum: bool, mirror: bool, allow_empty: bool, patterns: []String) -> Result<RunStats> {
    let job: Job = enumerate(src)?
    let root = job.root
    let files = job.targets
    let single = fs.is_file(src)

    // -- mirror-mode guards, before a single byte is written --------------
    if mirror {
        if single {
            bail "--delete needs a source directory, not a single file"
        }
        if mode == "move" {
            bail "--delete and move together would empty the source; use copy"
        }
        if !fs.is_dir(dst) {
            bail "--delete needs an existing destination directory: " + dst
        }
        let sdir = trim_dir(src)
        let ddir = trim_dir(dst)
        if sdir == ddir {
            bail "--delete refuses identical source and destination: " + sdir
        }
        if ddir.starts_with(sdir + "/") {
            bail "--delete refuses a destination inside the source: " + ddir
        }
        if sdir.starts_with(ddir + "/") {
            bail "--delete refuses a source inside the destination: " + sdir
        }
        if files.len() == 0 {
            let probe: Walk = walk_root(dst, "", [], [], 0)?
            if probe.files.len() > 0 && !allow_empty {
                bail "source has no files and the destination has " + probe.files.len().to_string() + "; refusing to empty it (--allow-empty overrides)"
            }
        }
    }

    var stats = RunStats { copied: 0, deleted: 0, skipped: 0, failed: 0, verified: 0, metadata_ok: 0, resumed: 0, bytes: 0, elapsed_ms: 0 }
    let t0 = time.monotonic()

    if !dry {
        for d in job.dirs {
            mkdir_p(dst + "/" + d)?
        }
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
                // Size and mtime are a cheap guess, not proof: a destination
                // corrupted in place keeps both. --checksum pays two hashes to
                // turn the guess into a fact before skipping.
                if checksum && Transfer.hash(from) != Transfer.hash(to) {
                    already = false
                }
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
                let outcome = copy_one(from, to, verify, allow_resume)
                match outcome {
                    Ok(done) -> {
                        // The native plane cannot infer a match payload's struct
                        // layout from the signature, so name the type.
                        let out: CopyOutcome = done
                        let a = fs.stat(from)?
                        stats.copied = stats.copied + 1
                        stats.bytes = stats.bytes + a.size
                        if out.meta_restored {
                            stats.metadata_ok = stats.metadata_ok + 1
                        }
                        if out.resumed_from > 0 {
                            stats.resumed = stats.resumed + 1
                        }
                        if verify {
                            stats.verified = stats.verified + 1
                        }
                        if !json {
                            print("copy  " + from + " -> " + to)
                        }
                        if mode == "move" {
                            // NOTE: on the native plane `fs.delete` fails loudly
                            // (exit 1) instead of returning Err, so a Result
                            // binding cannot be used here. Verify by observation:
                            // if the file is still there, the removal failed.
                            fs.delete(from)
                            if fs.exists(from) {
                                stats.failed = stats.failed + 1
                                if !json {
                                    print("FAIL  cannot remove source " + from)
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

    // A move that copied everything must also remove the source TREE. The
    // per-file deletions above leave the directory skeleton behind, so the
    // source looked "half moved" — all files gone, every directory still there.
    // Guarded by `failed == 0`: never delete a source whose copy had a failure.
    // fs.delete is recursive for directories, so one call finishes the job.
    if mode == "move" && !dry && stats.failed == 0 && !single {
        fs.delete(src)
    }
    // Mirror: remove what the source does not have. A failed copy means the
    // destination is missing a file the source HAS - prune never targets that -
    // but it also means the run is not trustworthy, so no prune happens at all.
    if mirror {
        if stats.failed > 0 {
            if !json {
                print("prune   skipped: " + stats.failed.to_string() + " copy failure(s) in this run")
            }
        } else {
            let plan: PrunePlan = prune_plan(files, job.dirs, dst, patterns)?
            let n: i64 = apply_prune(dst, plan, dry)?
            stats.deleted = n
        }
    }

    let t1 = time.monotonic()
    stats.elapsed_ms = (t1 - t0) / 1000000
    Ok(stats)
}

fn verify_tree(src: String, dst: String) -> Result<i64> {
    let job: Job = enumerate(src)?
    let root = job.root
    let files = job.targets
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
    // ASCII on purpose: engine releases up to 1.5.7 decode a multi-byte literal
    // one byte at a time, so an em dash here printed as mojibake. The lexer is
    // fixed in engine main; this line stays ASCII so a released engine renders
    // it correctly today.
    print("tallowx - verified copy/move for local and mounted storage")
    print("")
    print("  tallowx plan   SRC DST")
    print("  tallowx copy   SRC DST [--delete] [--exclude P] [--resume] [--checksum] [--no-verify] [--json]")
    print("  tallowx move   SRC DST [--resume] [--no-verify] [--json]")
    print("  tallowx verify SRC DST")
    print("")
    print("  --resume     complete a short destination from a hash-verified prefix")
    print("  --checksum   skip only after hashing both sides (catches in-place corruption)")
    print("  --delete     mirror: remove destination files the source does not have")
    print("  --exclude P  with --delete: keep paths matching P (exact, dir prefix, or *suffix)")
    print("  --allow-empty  with --delete: permit an empty source to empty the destination")
    print("  --no-verify  skip BLAKE3 read-back verification (faster; verifies nothing)")
    print("  --json       one machine-readable summary line")
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
    let allow_resume = has_flag(argv, "--resume")
    let checksum = has_flag(argv, "--checksum")
    let mirror = has_flag(argv, "--delete")
    let allow_empty = has_flag(argv, "--allow-empty")
    let patterns = flag_values(argv, "--exclude")

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

    let outcome = run(cmd, src, dst, verify, cmd == "plan", json, allow_resume, checksum, mirror, allow_empty, patterns)
    match outcome {
        // The native plane cannot type a `match` binding from the scrutinee's
        // Result payload, so the annotation here is what gives `stats` a layout.
        Ok(raw) -> {
            let stats: RunStats = raw
            if json {
                print('{"command":"' + cmd + '","copied":' + stats.copied.to_string() + ',"deleted":' + stats.deleted.to_string() + ',"skipped":' + stats.skipped.to_string() + ',"failed":' + stats.failed.to_string() + ',"verified":' + stats.verified.to_string() + ',"metadata_preserved":' + stats.metadata_ok.to_string() + ',"resumed":' + stats.resumed.to_string() + ',"bytes":' + stats.bytes.to_string() + ',"elapsed_ms":' + stats.elapsed_ms.to_string() + ',"mbps":' + mbps(stats.bytes, stats.elapsed_ms).to_string() + '}')
            } else {
                print("")
                print(cmd + ": " + stats.copied.to_string() + " file(s), " + stats.bytes.to_string() + " bytes, " + stats.elapsed_ms.to_string() + " ms")
                print("  verified: " + stats.verified.to_string() + " | metadata preserved: " + stats.metadata_ok.to_string() + " | skipped: " + stats.skipped.to_string() + " | failed: " + stats.failed.to_string())
            if mirror {
                print("  deleted: " + stats.deleted.to_string())
            }
                if stats.resumed > 0 {
                    print("  resumed: " + stats.resumed.to_string() + " file(s) completed from a verified prefix")
                }
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
