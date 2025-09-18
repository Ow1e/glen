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

