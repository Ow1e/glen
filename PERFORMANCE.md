## Performance opportunities and reliability considerations

This document captures observed hot paths and proposed improvements to increase throughput and reduce latency while preserving correctness and durability.

### Top priority (implemented)

- Batch WAL appends in replication apply
  - Build all `WalRecord` entries for a batch of remote changes, append once via `appendMany`, then apply in-memory mutations. This reduces syscall/lock overhead while keeping strict write-ahead semantics.

- Clone values in index-based reads
  - `findBy`/`rangeBy` now return cloned `Value`s to prevent external mutation of in-memory documents.

- Transaction read-set tuple keys
  - Store `Txn.readVersions` as `Table[(collection, docId), uint64]` to avoid string splits and reduce overhead in commit validation.

- Snapshot directory flush after rename
  - Call `flushDir(dir)` after atomic rename/move to strengthen durability of directory entries (best-effort on Windows; a no-op elsewhere for now).

- Optional fair mode for RwLock
  - Gate writer fairness with a compile-time flag (`-d:rwlockFair`): block new readers when writers are waiting to reduce write tail latency under heavy read load.

- Narrowed global locking
  - Introduced `replLock` to protect only `replSeq`, `localHlc`, and `replLog` updates; `put`, `delete`, and `commit` use per-collection stripe locks for data/index/cache and briefly take `replLock` for replication metadata. Replication apply uses stripes plus `replLock` for metadata decisions.

### High impact, next up (implemented)

- Narrow global write lock with a dedicated replication metadata lock
  - Introduce a `replLock` focused on `replSeq`, `localHlc`, `replLog`, and replication metadata to reduce contention with per-collection writes. Apply carefully to `put`/`delete`/`commit` once validated to maintain ordering and write-ahead guarantees.

- Replication export filtering/indexing
  - Implemented per-collection replication logs (`replLogByCollection`) and updated `exportChanges` to scan per-collection logs when filters are present. Global scan used for no-filter fast path. `gcReplLog` trims both global and per-collection logs.

- Peer cursor persistence batching
  - Implemented a 500 ms debounce for `peers.state` writes and ensured a flush on `close()`. Consider making the debounce configurable.

### Medium impact

- Cache tuning/admission
  - Expose/adapt `cacheShards` and capacity at runtime; consider lightweight admission (e.g., TinyLFU-like) if churn from scans is observed.

- WAL buffer reuse
  - Reuse encoding buffers in WAL append paths to reduce allocations and GC pressure.

### Reliability hardening

- Snapshot headers/checksums
  - Add magic/version/checksum to snapshots and verify on load.

- Configurable size limits
  - Make codec and snapshot size bounds configurable with sane defaults.

Notes
- Write-ahead ordering is preserved in replication apply by appending to WAL before mutating in-memory state.
- Writer fairness can be toggled at build time to fit workload characteristics without impacting default read performance.


