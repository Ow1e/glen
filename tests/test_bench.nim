import std/os
import std/times
import std/strformat
import glen/db as glendb, glen/types, glen/txn

proc benchPut(db: glendb.GlenDB; N: int) =
  let t0 = epochTime()
  for i in 0 ..< N:
    var v = VObject()
    v["n"] = VInt(i.int64)
    db.put("bench", "k" & $i, v)
  let dtMs = int64((epochTime() - t0) * 1000.0)
  let rate = if dtMs == 0: 0.0 else: (float(N) * 1000.0) / float(dtMs)
  echo &"BENCH puts: {N} ops in {dtMs} ms => {rate:.1f} ops/s"

proc benchGet(db: glendb.GlenDB; N: int) =
  let t0 = epochTime()
  var sum = 0
  for i in 0 ..< N:
    let k = i mod N
    let v = db.get("bench", "k" & $k)
    if not v.isNil: inc sum
  let dtMs = int64((epochTime() - t0) * 1000.0)
  let rate = if dtMs == 0: 0.0 else: (float(N) * 1000.0) / float(dtMs)
  echo &"BENCH gets: {N} ops in {dtMs} ms => {rate:.1f} ops/s (hits {sum})"

proc benchGetMany(db: glendb.GlenDB; N: int; batchSize: int) =
  ## Prepare ids
  var ids: seq[string] = @[]
  for i in 0 ..< N:
    ids.add("k" & $i)
  let t0 = epochTime()
  var pos = 0
  var hits = 0
  while pos < ids.len:
    let until = min(pos + batchSize, ids.len)
    let sliceIds = ids[pos ..< until]
    for (_, v) in db.getMany("bench", sliceIds):
      if not v.isNil: inc hits
    pos = until
  let dtMs = int64((epochTime() - t0) * 1000.0)
  let ops = (ids.len div batchSize) + (if ids.len mod batchSize == 0: 0 else: 1)
  let rate = if dtMs == 0: 0.0 else: (float(ops) * 1000.0) / float(dtMs)
  echo &"BENCH getMany: {N} docs in {dtMs} ms => {rate:.1f} batches/s (hits {hits})"

proc benchTxn(db: glendb.GlenDB; N: int) =
  let t0 = epochTime()
  for i in 0 ..< N:
    let t = db.beginTxn()
    var v = VObject()
    v["x"] = VInt(i.int64)
    t.stagePut(Id(collection: "benchTxn", docId: "t" & $i, version: 0'u64), v)
    discard db.commit(t)
  let dtMs = int64((epochTime() - t0) * 1000.0)
  let rate = if dtMs == 0: 0.0 else: (float(N) * 1000.0) / float(dtMs)
  echo &"BENCH txn commits: {N} ops in {dtMs} ms => {rate:.1f} ops/s"

when isMainModule:
  let dir = getTempDir() / "glen_bench_db"
  if dirExists(dir): removeDir(dir)
  let database = newGlenDB(dir)
  let N = 5000
  benchPut(database, N)
  benchGet(database, N)
  benchGetMany(database, N, 100)
  benchTxn(database, 1000)
  database.close()

