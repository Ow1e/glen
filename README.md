# Glen

Glen is a wickedly fast embedded document database written in Nim. It offers:

- Convex-like rich value types
- Durable write-ahead log with per-record checksums and segment headers
- Atomic snapshots (temp file + rename) and manual compaction with WAL truncation
- Dynamic adaptive LRU caching layer
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

By default Glen flushes (`fsync`) on every append for maximum durability. You can tune this:

- `wsmAlways` (default): flush every WAL append.
- `wsmInterval`: batch fsyncs based on a byte threshold.
- `wsmNone`: rely on OS page cache (fastest, least durable).

Usage:

```nim
import glen/db, glen/wal

let db = newGlenDB("./mydb", walSync = wsmInterval)      # interval policy
db.wal.setSyncPolicy(wsmInterval, flushEveryBytes = 1_048_576)  # 1 MiB batches
```

Note: On Windows, directory metadata is flushed when new WAL segments or snapshots are created. On POSIX, standard file flush is used.

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

Run the suite:

```
nimble test
```

Topic-specific tests are under `tests/`.