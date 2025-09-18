## Glen TODO

### High-impact improvements (prioritized)

- [ ] Durability and recovery
  - [ ] Add WAL archival/rotation policy and size-based retention
  - [ ] Build crash/recovery stress test harness (power-failure simulation)
  - [ ] Benchmarks for recovery time and durability trade-offs

- [ ] Bounds and input validation
  - [ ] Make max sizes configurable (env/config) rather than constants
  - [ ] Add decode/encode streaming APIs for very large values

- [ ] Determinism and canonical encoding
  - [ ] Sort object keys and document ids when encoding/snapshotting to achieve stable, canonical encodings (useful for hashing/replication).
  - [ ] Add snapshot headers (magic + version + checksum) for `*.snap` files.

-- [ ] Concurrency safety
  - [x] Move subscriber notifications outside DB lock and batch them
  - [x] Replace global lock with read-write lock for better read concurrency
  - [x] Fix stale index entries on updates (reindex old->new) and deletes
  - [x] Ensure WAL replay delete unindexes using prior document
  - [ ] Add contention/throughput tests with mixed readers/writers

-- [ ] Transaction correctness
  - [x] Return clones from reads to prevent external mutation of store values
  - [ ] Property tests for isolation (no phantom writes/reads) and version monotonicity

- [ ] API ergonomics and safety
  - [ ] JSON bridging (encode/decode) helpers
  - [ ] Batch operations (multi-put/delete) and patch/merge helpers
  - [ ] Query/filter API extensions (predicates, projections, pagination)
  - [x] Field-level subscriptions (callbacks and streams)
  - [x] Delta field subscriptions (append/replace/delete/set) with streaming
  - [ ] Backpressure/buffering options for streaming notifications

- [ ] Storage and snapshots
  - [x] Write snapshots atomically (`.tmp` + rename) and fsync the file and directory (best-effort on Windows).
  - [x] Manual compaction API with WAL truncation after snapshot (`db.compact()`).
  - [ ] Add periodic/threshold-based auto-compaction policy.
  - [ ] Backup/restore utility using snapshots + recent WAL

- [ ] Error handling
  - [ ] Standardize error codes/messages for external consumption

- [ ] Performance
  - [x] Reduce allocations in the codec by reusing buffers; optionally add a streaming encode/decode API.
  - [x] Pre-size `seq`/tables consistently when counts are known.
  - [x] Order-preserving index keys for floats; deterministic keying for bytes/arrays
  - [ ] Replace sorted-seq index `keys` with tree/B-tree to avoid O(n) inserts
  - [ ] Optional payload compression (e.g., zstd) for WAL segments after correctness is solid.
  - [ ] Microbenchmarks (encode/decode, get/put, commit) and perf CI gate
  - [ ] Cache metrics (hit/miss/evictions) and adaptive tuning hooks

- [ ] Testing
  - [x] WAL replay, including partial/corrupt tail handling.
  - [x] Snapshot round-trip.
  - [x] Subscriptions for put/delete and transactional writes.
  - [x] OCC success and conflict paths.
  - [x] Cache behavior (eviction).
  - [x] Fuzz tests for `codec` and snapshot round-trip.
  - [ ] Tests for WAL sync policies (always/interval/none)
  - [ ] Windows-specific durability paths.
  - [x] Soak tests (long-running concurrency + durability)
  - [ ] Property tests for transactions (isolation, version monotonicity)
  - [ ] Indexing and query tests for range edges and composite ordering

- [ ] Docs and DX
  - [x] Nim doc comments for public types/procs; generate and publish docs.
  - [x] Expand README with usage examples, durability guarantees, and WAL/snapshot layout references.
  - [x] Document WAL sync policy options in README with examples
  - [x] Document streaming codec and streaming/field subscriptions in README
  - [x] CI across Linux and Windows; test Nim 1.6 and 2.x (ARC/ORC).
  - [ ] Publish docs (GitHub Pages) and add CONTRIBUTING.md
  - [ ] Add CHANGELOG and versioning/release notes process

- [ ] Housekeeping
  - [x] Remove the placeholder guard in `src/glen/glen.nim` (`when not declared(Value)`).
  - [x] Update `examples/basic.nim` to either complete and commit the transaction or remove unused txn code; show a committed txn example.
  - [x] Split tests into topic-specific files and update `glen.nimble`.

### Quick wins

- [ ] Auto-compaction threshold + timer
- [ ] Publish docs site via GitHub Pages


