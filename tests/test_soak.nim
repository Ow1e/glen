import std/os
import std/unittest
import std/random
import glen/db, glen/types, glen/txn

proc randKey(maxId: int): string =
  "k" & $rand(maxId)

suite "soak (short)":
  test "heavy mixed ops with periodic compaction and reopen":
    randomize()
    let dir = getTempDir() / "glen_test_soak"
    if dirExists(dir): removeDir(dir)
    var db = newGlenDB(dir)
    let numKeys = 50
    let totalOps = 2000
    for i in 0 ..< totalOps:
      let r = rand(100)
      if r < 50:
        # put
        let k = randKey(numKeys)
        var v = VObject()
        v["v"] = VInt(rand(1000).int64)
        db.put("items", k, v)
      elif r < 80:
        # delete
        let k = randKey(numKeys)
        db.delete("items", k)
      elif r < 90:
        # transaction: read then write
        let k = randKey(numKeys)
        let t = db.beginTxn()
        discard db.get("items", k, t)
        var v = VObject(); v["v"] = VInt(rand(1000).int64)
        t.stagePut(Id(collection: "items", docId: k, version: 0'u64), v)
        discard db.commit(t)
      else:
        # occasional snapshot or compaction
        if (i mod 200) == 0:
          db.snapshotAll()
        if (i mod 500) == 0:
          db.compact()
      # periodically reopen to exercise recovery
      if (i > 0) and (i mod 700) == 0:
        db.close()
        db = newGlenDB(dir)
    # final durability check: compact and reopen
    db.compact()
    db.close()
    db = newGlenDB(dir)
    # sanity: random gets should not crash
    for _ in 0 ..< 100:
      discard db.get("items", randKey(numKeys))
    db.close()

  test "striped locks reduce contention across collections (smoke)":
    randomize()
    let dir = getTempDir() / "glen_test_stripes"
    if dirExists(dir): removeDir(dir)
    let db = newGlenDB(dir, lockStripesCount = 32)
    # Populate multiple collections in quick succession; ensure no deadlocks and correctness
    for i in 0 ..< 200:
      let coll = if (i mod 2) == 0: "cA" else: "cB"
      db.put(coll, "k" & $i, VInt(i.int64))
    # Interleave batch ops across collections
    db.putMany("cA", @[("ka1", VInt(1)), ("ka2", VInt(2)), ("ka3", VInt(3))])
    db.putMany("cB", @[("kb1", VInt(1)), ("kb2", VInt(2))])
    # Validate reads from both collections
    check db.get("cA", "ka1") == VInt(1)
    check db.get("cB", "kb2") == VInt(2)
    # Multi-collection transaction: should not deadlock
    let t = db.beginTxn()
    t.stagePut(Id(collection: "cA", docId: "ta", version: 0'u64), VInt(10))
    t.stagePut(Id(collection: "cB", docId: "tb", version: 0'u64), VInt(20))
    let res = db.commit(t)
    check res.status == csOk
    check db.get("cA", "ta") == VInt(10)
    check db.get("cB", "tb") == VInt(20)
    # Snapshot/compact under stripes
    db.snapshotAll()
    db.compact()
    db.close()
