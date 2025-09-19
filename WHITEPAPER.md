## Glen: An Embedded Document Database for Nim

### TL;DR
Glen is a fast, embedded, single-process document database for Nim. It stores data in-memory for speed, persists mutations via a write-ahead log (WAL), periodically takes snapshots per collection for fast recovery, offers optimistic transactions (OCC), field and document subscriptions, indexes for equality and simple ranges, and a sharded LRU cache. It is designed for local-first apps, edge/embedded services, tests, analytics dashboards, and single-node real-time workloads.

---

## 1. Overview and Goals
Glen aims to provide:
- Low-latency reads/writes with in-memory data structures
- Durability via WAL + snapshot recovery
- Lightweight optimistic transactions
- Real-time subscriptions at document and field granularity
- Simple indexes (equality, single-field ranges)
- Small, clear core that is easy to reason about and embed

Non-goals (for now):
- Distributed consensus or replication
- Cross-process concurrency/multiprocess durability guarantees
- Heavy SQL-like query planning

---

## 2. Data Model
- Collections: Named buckets of documents.
- Document Id: `Id` holds `(collection: string, docId: string, version: uint64)`.
- Value: Variant type supporting null, bool, int, float, string, bytes, array, object, and id.
- Versioning: Each doc has a monotonically increasing version; used for OCC and subscriptions.

---

## 3. Architecture

### 3.1 In-Memory State
- `collections`: `Table[string, Table[string, Value]]`
- `versions`: `Table[string, Table[string, uint64]]`
- `indexes`: `Table[string, IndexesByName]`
- Synchronization: Reader-prefer `RwLock` protecting DB state (future: per-collection locks).

### 3.2 Sharded LRU Cache
- Purpose: Reduce read latency and lock contention.
- Design: `numShards` shards keyed by hash of `collection:docId`, each with its own lock and LRU list.
- Capacity: Global capacity split across shards.
- Metrics: Per-shard and aggregate hits, misses, puts, evictions via `cache.stats()`.

### 3.3 Write-Ahead Log (WAL)
- Segmented files: `glen.wal.0`, `glen.wal.1`, ...
- Record format: `varuint bodyLen | uint32 checksum | body`.
- Body encoding: `varuint recordType | collection | docId | version | valueLen(+value)`.
- Sync policies:
  - `wsmAlways`: fsync after each append.
  - `wsmInterval`: fsync after `flushEveryBytes` written (default); balances throughput and durability window.
  - `wsmNone`: rely on OS buffering.
- Batching: Commits build multiple `WalRecord`s and append them via `appendMany` to minimize flushes.
- Rotation: New segment when max size exceeded; durable magic/version header on first write.
- Recovery: On open, replay all segments after loading snapshots; tail corruption tolerated.

### 3.4 Snapshots
- Per-collection snapshot file: `collection.snap`.
- Atomic write via temp file + rename.
- Recovery: Load snapshots, then replay WAL to the latest state.
- Compaction: `db.compact()` snapshots all collections and resets the WAL to bound replay time.

### 3.5 Transactions (OCC)
- Begin: `db.beginTxn()` creates a `Txn` (active state).
- Read-tracking: `db.get(..., t: Txn)` records the version observed.
- Staging: `t.stagePut(id, value)` / `t.stageDelete(collection, docId)`.
- Commit:
  1) Validate all observed versions against current versions; conflict → rollback.
  2) Compute new versions; build WAL records; update in-memory state and cache; reindex.
  3) Batch-append WAL; notify subscribers after releasing the write lock.

### 3.6 Subscriptions
- Document-level: Subscribers receive new Value for a `(collection, docId)` on change.
- Field-level: Subscribers can target field paths; delta callbacks available.
- Stream APIs: Write framed events to a stream for integration with external consumers.

### 3.7 Indexes
- Equality and range (single-field) support; composite equality via serialized composite keys.
- Internals: `Table[string, HashSet[string]]` for postings; `CritBitTree` for ordered range keys.
- Maintenance: On put/delete/commit, indexes update by (re)indexing affected docs.

### 3.8 Codec
- Value encode/decode used by WAL and snapshots. Supports all `Value` kinds.

---

## 4. Concurrency Model
- Core state protected by a reader-prefer `RwLock`: readers proceed unless a writer holds the lock.
- Cache is sharded; each shard has its own lock; drastically reduces contention for hot reads.
- Transactions are optimistic: conflicts are detected at commit by comparing versions.

### Borrowed Reads
- Standard reads (`get`, `getMany`, `getAll`) return deep clones.
- Borrowed APIs (`getBorrowed`, `getBorrowedMany`, `getBorrowedAll`) return references for speed.
- Important: Borrowed Values are read-only; callers must not mutate them. They may be shared across threads through the cache.

---

## 5. Durability, Recovery, and Compaction
- Durability relies on WAL policy:
  - `wsmAlways` → strongest; lowest throughput.
  - `wsmInterval` → default; tunable window (e.g., 8–64 MiB) balances throughput and loss window.
  - `wsmNone` → fastest; crash may lose recent writes buffered by OS.
- Recovery: Load each `collection.snap`, then `replay(dir)` all WAL segments. Tail corruption is tolerated (records are length+checksum delimited).
- Compaction: Call `db.compact()` periodically or when `wal.totalSize()` exceeds a threshold. This writes snapshots and then truncates the WAL via `wal.reset()`.

---

## 6. Performance Guide

### 6.1 Quick Wins
- Use `wsmInterval` with a larger `walFlushEveryBytes` (8–64 MiB) for higher write throughput.
- Increase `cacheCapacity` and `cacheShards` if memory and cores allow.
- Prefer batch APIs (`getMany`) to amortize locks.
- Use borrowed reads in hot paths when safe to avoid clones.

### 6.2 Transaction Path Optimizations
- Batched WAL appends reduce flushes and syscalls.
- Avoid string parsing: transaction write keys are `(collection, docId)` tuples.
- Pre-encode values outside critical sections if you extend the API for external batched puts.

### 6.3 Indexing Strategy
- Add equality indexes for frequent filters; use single-field range indexes for ordered scans.
- Avoid frequent churn on high-cardinality indexes unless necessary.

### 6.4 Locking Strategy
- Reader-prefer RW lock benefits read-heavy workloads.
- Future: per-collection locks or striped locks to reduce global contention under mixed workloads.

### 6.5 Monitoring
- Expose and monitor `db.cacheStats()` to track hit rates and shard imbalances.
- Track `wal.totalSize()` to schedule compaction.

---

## 7. Operational Guidance

### 7.1 Files and Layout
- Database directory contains `*.snap` (one per collection) and WAL segments `glen.wal.N`.

### 7.2 Configuration
- Constructor: `newGlenDB(dir; cacheCapacity, cacheShards, walSync, walFlushEveryBytes)`.
- Runtime WAL policy: `db.setWalSync(mode, flushEveryBytes)`.
- Cache capacity can be adjusted at runtime: `cache.adjustCapacity(newCap)`.

### 7.3 Backup and Restore
- Snapshot-based backup: call `snapshotAll`, copy `*.snap` and WAL segments.
- Restore by placing snapshots and WAL files in the data directory; Glen replays WAL on open.

### 7.4 Compaction Policy
- Periodically call `db.compact()` or trigger it when WAL crosses a size threshold.

---

## 8. Best Use Cases
- Local-first or offline-first applications needing fast embedded storage and real-time updates.
- Edge services where a single-process database suffices.
- Real-time dashboards; reactive UIs via subscriptions.
- Analytics or caching layers with small-to-medium datasets fitting in memory.
- Single-node event logging or event sourcing with periodic snapshotting.
- Testing/prototyping environments that need strong performance and simple APIs.

---

## 9. When Not to Use Glen
- Distributed systems requiring replication, failover, or consensus.
- Data sizes far exceeding available memory (Glen keeps active working set in RAM).
- Heavy multi-process writers or cross-process concurrency with strict durability semantics.
- Complex ad-hoc queries requiring advanced indexing or query planning.

---

## 10. Application Patterns
- Event Sourcing: Store events as docs; periodically materialize snapshots; truncate WAL.
- CQRS: Use equality/range indexes to power query side; apply writes via OCC.
- Streaming Updates: Subscribe to hot documents/fields; feed to UI or downstream.
- IoT/Edge: Local persistence with intermittent compaction; ship snapshots upstream if needed.

---

## 11. API Highlights
- Creation: `newGlenDB(dir; cacheCapacity, cacheShards, walSync, walFlushEveryBytes)`
- Basic Ops: `put`, `get`, `getMany`, `getAll`, `delete`
- Borrowed Reads: `getBorrowed`, `getBorrowedMany`, `getBorrowedAll` (do not mutate)
- Transactions: `beginTxn`, `get(..., t)`, `getMany(..., t)`, `commit`, `rollback`
- Indexes: `createIndex`, `dropIndex`, `findBy`, `rangeBy`
- Subscriptions: `subscribe`, `unsubscribe`, field/stream/delta variants
- Maintenance: `snapshotAll`, `compact`, `close`
- Tuning/Introspection: `setWalSync`, `cacheStats()`, `wal.totalSize()`

---

## 12. Benchmarks and Methodology
The repo includes `tests/test_bench.nim` which runs puts/gets/getMany/txn commit micro-benchmarks. Numbers vary by machine and configuration (sync mode, cache size/shards). For realistic workloads, prefer application-level benchmarks.

---

## 13. Roadmap Ideas
- Per-collection/striped locks to reduce contention further.
- Background/online compaction and incremental snapshots.
- Compression (e.g., zstd) for WAL and snapshots.
- Range iterators and borrowed-result query APIs.
- Encryption at rest; integrity metadata beyond checksums.
- Replication plugins or changefeed export.

---

## 14. Security and Safety Notes
- Borrowed Values are shared references; treat them as immutable.
- WAL `wsmNone` and large `wsmInterval` increase risk of recent-write loss on crash.
- Snapshots replace files atomically; ensure the host filesystem semantics match the documented behavior for your platform.

---

## 15. Conclusion
Glen provides a compact, high-performance embedded datastore with pragmatic durability, optimistic transactions, subscriptions, and indexing. It fits best where single-process latency matters, the working set largely fits in memory, and simplicity is valued over distributed complexity.


