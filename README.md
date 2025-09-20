# Glen

Glen is a wickedly fast embedded document database written in Nim. It offers:

- Convex-like rich value types
- Durable write-ahead log with per-record checksums and segment headers
- Atomic snapshots (temp file + rename) and manual compaction with WAL truncation
- Dynamic adaptive LRU caching layer
- Sharded LRU cache with per-shard locks and tunable capacity/shards
- Optimistic multi-document transactions (CommitResult status on commit)
- Fine-grained subscriptions to specific documents (collection + id)
- Compact binary codec with bounds checks
- Indexing and queries:
  - Equality indexes (single-field and composite keys)
  - Range scans (single-field), orderBy (asc/desc), and limit

> Status: Prototype (0.1.0) — Work in progress.

## Roadmap

1. Auto-compaction policy
2. Advanced query & indexing (filters, projections, pagination/cursors)
3. Secondary indexes
4. Replication

## License
MIT

## Quick start

```nim
import glen/types, glen/db

let db = newGlenDB("./mydb")
db.put("users", "u1", VObject())
echo db.get("users", "u1")

let t = db.beginTxn()
t.stagePut(Id(collection: "users", docId: "u2", version: 0'u64), VString("Alice"))
let res = db.commit(t)
echo res.status
```

## Examples

### CRUD

```nim
import glen/types, glen/db

let db = newGlenDB("./mydb")

var user = VObject()
user["name"] = VString("Alice")
user["age"] = VInt(30)

db.put("users", "u1", user)
echo db.get("users", "u1")           # {age: 30, name: "Alice"}

db.delete("users", "u1")
echo db.get("users", "u1") == nil     # true

# Batch writes to reduce lock overhead
db.putMany("users", @[("u2", VString("a")), ("u3", VString("b"))])
db.deleteMany("users", @["u2", "u3"]) 
```

### Transactions (optimistic)

```nim
import glen/types, glen/db, glen/txn

let db = newGlenDB("./mydb")
db.put("items", "i1", VString("old"))

let t = db.beginTxn()
discard db.get("items", "i1", t)       # record read version
t.stagePut(Id(collection: "items", docId: "i1", version: 0'u64), VString("new"))
let res = db.commit(t)                    # CommitResult
echo res.status                           # csOk or csConflict

```
### Borrowed reads (no clone)

Borrowed variants return shared references for performance. Do not mutate the returned `Value`. Ideal for read-only hot paths.

```nim
let vRef = db.getBorrowed("users", "u1")
for (id, v) in db.getBorrowedMany("users", @[["u1", "u2"]]): discard
for (id, v) in db.getBorrowedAll("users"): discard
```
### Subscriptions


```nim
import glen/types, glen/db

let db = newGlenDB("./mydb")
let h = db.subscribe("users", "u1", proc(id: Id; v: Value) =
  echo "Update:", $id, " -> ", $v
)
db.put("users", "u1", VObject())
db.unsubscribe(h)
```

### Snapshots and compaction

```nim
import glen/db
let db = newGlenDB("./mydb")
db.snapshotAll()     # write all collections to snapshots
db.compact()         # snapshot + truncate WAL
```

### Indexing and queries

Create an equality index, then query by value (with optional limit):

```nim
import glen/types, glen/db

let db = newGlenDB("./mydb")
db.createIndex("users", "byName", "name")

var u1 = VObject(); u1["name"] = VString("Alice"); db.put("users", "1", u1)
var u2 = VObject(); u2["name"] = VString("Bob");   db.put("users", "2", u2)
var u3 = VObject(); u3["name"] = VString("Alice"); db.put("users", "3", u3)

for (id, v) in db.findBy("users", "byName", VString("Alice"), 10):
  echo id, " -> ", v
```

Composite keys and range scans with order and limit:

```nim
import glen/types, glen/db

let db = newGlenDB("./mydb")
db.createIndex("users", "byNameAge", "name,age")   # composite equality
db.createIndex("users", "byAge", "age")            # single-field, rangeable

var u1 = VObject(); u1["name"] = VString("Alice"); u1["age"] = VInt(30); db.put("users", "1", u1)
var u2 = VObject(); u2["name"] = VString("Bob");   u2["age"] = VInt(25); db.put("users", "2", u2)
var u3 = VObject(); u3["name"] = VString("Alice"); u3["age"] = VInt(35); db.put("users", "3", u3)

# composite equality
for (id, _) in db.findBy("users", "byNameAge", VArray(@[VString("Alice"), VInt(30)])):
  echo id   # 1

# range scan by age (ascending)
for (id, _) in db.rangeBy("users", "byAge", VInt(26), VInt(40), true, true, 0, true):
  echo id   # 1, 3

# descending with limit
for (id, _) in db.rangeBy("users", "byAge", VInt(0), VInt(40), true, true, 2, false):
  echo id   # 3, 1
```

### Safe getters and typed accessors

```nim
import glen/types
var o = VObject()
o["b"] = VBool(true)
o["n"] = VInt(7)
o["s"] = VString("x")

discard o.hasKey("b")               # true
echo o.getOrNil("missing") == nil   # true
echo o.getOrDefault("missing", VString("def")).toStringOpt().get()  # def
echo o["n"].toIntOpt().get()        # 7
```

## Durability

- Write-Ahead Log with per-record checksums and segment headers (magic + version)
- Snapshot files are written atomically (temp-file + rename) with best-effort directory flush on Windows
- Recovery: load snapshots first, then replay WAL segments until the tail

### WAL sync policy (durability vs throughput)

By default Glen uses interval flushing for better throughput. You can tune this:

- `wsmAlways`: flush every WAL append (most durable, slowest).
- `wsmInterval` (default): batch fsyncs based on a byte threshold.
- `wsmNone`: rely on OS page cache (fastest, least durable).

Usage:

```nim
import glen/db, glen/wal

let db = newGlenDB("./mydb", walSync = wsmInterval)      # interval policy
db.setWalSync(wsmInterval, flushEveryBytes = 8 * 1024 * 1024)   # 8 MiB batches

# Or via environment variables and helper:
# set GLEN_WAL_SYNC=interval
# set GLEN_WAL_FLUSH_BYTES=8388608
# set GLEN_CACHE_CAP_BYTES=67108864
# set GLEN_CACHE_SHARDS=16
let db2 = newGlenDBFromEnv("./mydb2")

### Concurrency (striped locks)

Glen uses striped read/write locks per collection to reduce contention under mixed workloads. You can tune the stripe count:

```nim
let db = newGlenDB("./mydb", cacheCapacity = 128*1024*1024, cacheShards = 32, lockStripesCount = 32)
```

Transactions spanning multiple collections lock the needed stripes in a fixed order to avoid deadlocks.
**Note: On Windows, directory metadata is flushed when new WAL segments or snapshots are created. On POSIX, standard file flush is used.**

## Multi-Master Replication (see multi-comm branch)

Glen provides a transport-agnostic API for multi-master sync. You wire the transport; Glen handles filtering, idempotency, and conflict resolution (HLC-based LWW).

- Change export (filterable):
  - `exportChanges(sinceCursor, includeCollections = @[], excludeCollections = @[]) -> (nextCursor, changes)`
  - If `includeCollections` is non-empty, only those are sent. Collections in `excludeCollections` are omitted.
- Apply changes (idempotent, LWW):
  - `applyChanges(changes)` updates local state, indexes, cache, and fires subscriptions.
- Node identity (optional):
  - Set `GLEN_NODE_ID` to a stable node id; otherwise one is generated.

Minimal flow (peer-to-peer):

```nim
# On sender (A)
var cursorForB: uint64 = 0
let (nextCursor, batch) = dbA.exportChanges(cursorForB, includeCollections = @("users"))  # you choose filters
# send `batch` to B via your transport

# On receiver (B)
dbB.applyChanges(batch)
# On sender (A)
cursorForB = nextCursor  # persist per-peer cursor
```

Bootstrap a new node (B):
- Choose collections B wants; copy snapshots for those collections (or send a bulk dump).
- Initialize B, load snapshots, then start tailing A with exportChanges from an agreed cursor using the same filters.

Topologies:
- Full mesh or hub/spoke; keep one export cursor per peer. Changes can traverse multiple hops; duplicates are ignored and conflicts converge via LWW.

## Binary formats

- Codec: tagged binary format (null/bool/int/float/string/bytes/array/object/id) with varuints and zigzag ints
- Snapshot: varuint count, then (idLen|id|valueLen|valueBinary) repeated

### Streaming codec and runtime limits

Glen’s codec is available in two forms:

- Buffer API: `encode(value): string` and `decode(string): Value`
- Streaming API: `encodeTo(stream, value)` and `decodeFrom(stream)` (exported via `glen/codec_stream`).

Runtime limits are configurable via environment variables (defaults in parentheses):

- `GLEN_MAX_STRING_OR_BYTES` (16 MiB)
- `GLEN_MAX_ARRAY_LEN` (1,000,000)
- `GLEN_MAX_OBJECT_FIELDS` (1,000,000)

Example:

```bash
set GLEN_MAX_STRING_OR_BYTES=33554432
set GLEN_MAX_ARRAY_LEN=2000000
set GLEN_MAX_OBJECT_FIELDS=2000000
```

Streaming usage:

```nim
import std/streams
import glen/types, glen/codec_stream

var ss = newStringStream()
encodeTo(ss, VArray(@[VInt(1), VString("x")]))
ss.setPosition(0)
let v = decodeFrom(ss)
```

### Streaming subscriptions

You can stream document updates to any `Stream`. Each event is a Glen `Value` object encoded with the streaming codec and has fields: `collection`, `docId`, `version`, `value`.

```nim
import std/streams
import glen/glen

let db = newGlenDB("./mydb")
var ss = newStringStream()
let h = db.subscribe("users", "u1", proc (id: Id; v: Value) = discard)  # regular callback
let hs = db.subs.subscribeStream("users", "u1", ss)                      # streaming

db.put("users", "u1", VString("hi"))

ss.setPosition(0)
let ev = decodeFrom(ss)                   # => {collection:"users", docId:"u1", version:1, value:"hi"}

db.unsubscribe(hs)
```

### Field-level subscriptions

Subscribe to a single field path on a document. Callbacks fire only if that field’s value actually changes (deep equality):

```nim
import glen/glen

let db = newGlenDB("./mydb")
let h = db.subscribeField("users", "u1", "profile.age", proc(id: Id; path: string; oldV: Value; newV: Value) =
  echo path, ": ", $oldV, " -> ", $newV
)

db.put("users", "u1", VObject())                # no event
var u = VObject(); var p = VObject(); p["age"] = VInt(30); u["profile"] = p
db.put("users", "u1", u)                         # profile.age: nil -> 30 (fires)

db.unsubscribeField(h)
```

You can also stream field-level events to a `Stream` with `subscribeFieldStream`.

#### Delta field subscriptions

For large strings or frequently-growing values, subscribe to just the delta:

```nim
let h = db.subscribeFieldDelta("logs", "x1", "text", proc(id: Id; path: string; delta: Value) =
  # delta is an object with { kind: "append"|"replace"|"delete"|"set", ... }
  echo delta
)

var v = VObject(); v["text"] = VString("hello")
db.put("logs", "x1", v)                      # {kind:"set", new:"hello"}
v["text"] = VString("hello world")
db.put("logs", "x1", v)                      # {kind:"append", added:" world"}

db.unsubscribeFieldDelta(h)
```

Delta stream: `subscribeFieldDeltaStream` writes framed events with `{collection, docId, version, fieldPath, delta}`.

## Testing

Run the suite (debug):

```
nimble test
```
Release/optimized run (ORC + O3):

```
nimble test_release
nimble bench_release
```
Topic-specific tests are under `tests/`.