## AI Agent Coding and Testing Guide (Glen)

This guide explains how to write code, run tests, and operate effectively as an agent on this repository.

### Principles

- **Safety first**: prefer correctness, durability, and concurrency safety over micro-optimizations.
- **Small, reviewable edits**: scope changes narrowly; keep unrelated code untouched.
- **Always leave the tree green**: run tests after changes and fix regressions before moving on.

## Workflow

### 1) Discovery and context

- Read `README.md`, `glen.nimble`, and relevant modules under `src/glen/`.
- Skim tests under `tests/` to understand guarantees and expected behavior.
- If exploring code, use focused reads; avoid wide, speculative edits.

### 2) Plan with a todo list

- For multi-step tasks, create a short todo list and keep it updated as you progress.
- Keep one item `in_progress`; mark items `completed` as soon as they’re done.

### 3) Making code changes

- Add imports/deps needed for the code to compile; do not reformat unrelated code.
- Preserve existing indentation and whitespace style.
- Follow the project code style (see below) and avoid dead code.
- After each meaningful change, run the test suite.

### 4) Testing

- Run all tests:
  - `nimble test`
- Tests are split by topic:
  - `tests/test_db.nim` — basic ops and transaction paths
  - `tests/test_wal_snapshot.nim` — WAL replay and snapshot round-trip
  - `tests/test_subscriptions.nim` — subscribe/unsubscribe and notifications
  - `tests/test_cache.nim` — LRU eviction behavior
  - `tests/test_codec.nim` — codec and snapshot fuzz
- Add new tests in a new file under `tests/` with clear suite names; update `glen.nimble` if adding new files.
- Prefer deterministic tests; for fuzz tests, cap iterations and sizes.

## Code style (Glen)

- **Naming**: use descriptive identifiers. Avoid 1–2 char names. Functions should be verbs.
- **Types**: prefer explicit types for public APIs; avoid unsafe casts.
- **Control flow**: handle errors/edge cases early; avoid deep nesting; avoid empty catches.
- **Comments**: keep them short and focused on “why.” Do not narrate actions inside code bodies.
- **Formatting**: match existing style. Prefer multi-line clarity over clever one-liners.

## Glen architecture notes

### Value and codec

- `Value` supports `null/bool/int/float/string/bytes/array/object/id` with constructors like `VString`, `VObject`, etc.
- The binary codec enforces basic size limits; validate external inputs and keep limits in mind when adding features.

### WAL and recovery

- WAL (`src/glen/wal.nim`) uses per-record checksums; replay should stop at the first invalid record in a segment tail.
- Append operations must be flushed; consider platform-specific durability when changing WAL.

### Snapshots

- Snapshots are stored per-collection via `src/glen/storage.nim`.
- When changing snapshot format, add a header (magic + version) and maintain backward compatibility.

### Cache

- LRU cache (`src/glen/cache.nim`) is internally locked and is safe for concurrent access.
- Update the cache consistently on `put`, transactional `commit`, and invalidate on `delete`.

### Subscriptions

- Subscriber type is a closure `proc (id: Id; newValue: Value) {.closure.}` (converter exists for plain procs).
- `subscribe` returns a handle; use `unsubscribe` to detach.
- Notify on put and delete (delete emits `null`).

### Transactions

- Use explicit staged writes: `TxnWriteKind = twPut | twDelete`.
- `commit` validates read versions (OCC), applies writes atomically under the DB lock, updates versions and cache, and notifies subscribers.

## Patterns to follow

- **Concurrency**: hold the DB lock when mutating shared state; the cache has its own lock.
- **Durability**: append to WAL before mutating in-memory state; flush appropriately.
- **Versioning**: bump document versions for each write/delete and propagate into cache and notifications.

## Adding tests

- Create a new `tests/test_<topic>.nim` with one or more `suite` blocks.
- Keep tests independent (use `getTempDir()` for DB/WAL snapshot directories).
- For subscriptions, use closure callbacks; example:

```nim
let h = db.subscribe("users", "u1", proc(id: Id; v: Value) =
  events.add($id & "|" & $v)
)
db.unsubscribe(h)
```

## Useful commands

- Build and run a specific test file:
  - `nim c -r --path:src tests/test_db.nim`
- Run full suite:
  - `nimble test`

## Module-specific guidance

- `db.nim`: keep cache coherence and subscriber notifications aligned with writes; never bypass WAL.
- `wal.nim`: maintain checksum and length encoding; on replay, stop at corruption boundaries.
- `storage.nim`: enforce size limits; consider atomic writes for future improvements.
- `subscription.nim`: keep callbacks closure-based; ensure `unsubscribe` is safe and idempotent.
- `txn.nim`: keep staged writes explicit; avoid overloading special values.

## PR/commit guidance (if relevant)

- Small, focused commits with clear messages.
- Include test updates alongside code changes.
- Avoid flaky tests; keep fuzz counts conservative.


