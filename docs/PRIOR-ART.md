# Prior art

What already exists, what it is good at, and what this tool took from it.
Public documentation only.

## Copy tools

| Tool | Strong at | What `tallowx` took |
|---|---|---|
| `cp -a` (GNU coreutils) | Kernel copy path, metadata, zero dependency | The copy primitive itself: `std::fs::copy` uses `copy_file_range`/sendfile, which is why `tallowx` is at parity with `cp` and not faster |
| `rsync -a` | Delta transfer, re-runs, remote | The quick check — skip when size **and** mtime match, without hashing; and `--checksum` as the explicit, expensive option |
| `rclone` | Cloud backends, parallel transfers, post-copy verification | Verification as a post-transfer step against the destination, not a claim from the writer |
| `bbcp` | Multi-stream bulk transfer over a network | Nothing yet — its multi-stream model is the natural target once the engine has threads |
| `fpart` + `GNU parallel` | Partitioning a file list across workers | The plan: enumerate once, then hand disjoint file lists to workers. Blocked today on engine concurrency |
| `tar` + `pigz`/`zstd` + pipe | One stream, compression, simple | Nothing — `tallowx` copies files as files so a partial run is still usable |
| `dd` with large `bs` | Raw devices, explicit block size | Nothing — block-size tuning is a userspace loop the engine does not expose |

## Content-addressed and encrypted transfer

| Tool | Strong at | Relevance |
|---|---|---|
| `magic-wormhole` | Short-code pairing, PAKE, no account | The right model if this ever leaves one machine; the engine ships `crypto` (PQC, PAKE) and `transfer` (chunking, manifests) for that path |
| `croc` | PAKE + relay, cross-platform, resume | Same; also a reference for progress reporting over a lossy link |
| `Syncthing` | Continuous sync, block hashes, conflict handling | Its block-level hash index is the design a byte-level resume would use |
| `NNCP` | Store-and-forward, offline links, signed packets | Signed receipts — `tallow-jobs` already does this shape for job runs |
| `restic` / `borg` | Content-addressed snapshots, verifiable restores | The strongest form of "prove the bytes arrived": the destination is addressed by hash, so verification is inherent rather than bolted on |

## Filesystem-level transfer

`ZFS send/recv` and `btrfs send/recv` move a snapshot as a checksummed stream,
which beats any per-file copier on both speed and integrity for large trees.
They are the honest recommendation when source and destination are both ZFS or
both btrfs: use them, not this.

`tallowx` exists for the case where they are not available or not appropriate —
mixed filesystems, a NAS mounted over NFS/SMB, a one-off tree, a machine where
you want one portable tool and a verifiable record.

## Protocol and I/O research that informed the design

- **`copy_file_range(2)` / `sendfile(2)`** — why a userspace "faster copy" is
  mostly a myth on the same filesystem: the kernel already does it, and a
  read/write loop in userspace usually loses.
- **BLAKE3** — chosen by the engine for file hashing; tree mode is what makes
  per-chunk verification cheap enough to consider for parallel copy.
- **`io_uring`** — the engine has a backend behind a feature flag
  (`src/stdlib/io_backend.rs`), with a thread-pool fallback. Not exercised by
  this tool, because the copy path it uses never enters that code.
- **HTTP/3 and QUIC** — relevant only to the network end of the engine
  (`QuicTransfer`), out of scope for a local/NAS copier.
- **Erasure coding** (Reed–Solomon, `ErasureCode.*` in the engine) — for
  durability across unreliable links, not for a filesystem copy.

## Scope note

This project deliberately did **not** research intrusion methods, exfiltration
tradecraft, or material from closed criminal forums. That material does not
answer any question this tool asks, and collecting it would make the codebase
and its author complicit in things no transfer utility needs.

The legitimate version of "how do professionals move data fast and prove it
arrived" is fully public: kernel copy primitives, `rsync`'s quick check,
`rclone`'s post-copy verification, content-addressed backup, snapshot
send/recv, and the checksummed-stream literature those tools cite. Every design
decision in `tallowx` traces to that body of work.
