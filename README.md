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

## Binary formats

- Codec: tagged binary format (null/bool/int/float/string/bytes/array/object/id) with varuints and zigzag ints
- Snapshot: varuint count, then (idLen|id|valueLen|valueBinary) repeated

## Testing

Run the suite:

```
nimble test
```

Topic-specific tests are under `tests/`.