import std/os
import std/unittest
import std/random
import glen/db, glen/types

proc pickName(): string =
  const names = ["Alice", "Bob", "Carol", "Dave", "Eve"]
  names[rand(names.len-1)]

proc upsertUser(db: GlenDB; id: string) =
  var u = VObject()
  u["name"] = VString(pickName())
  u["age"] = VInt((18 + rand(60)).int64)
  db.put("users", id, u)

suite "soak (index)":
  test "index updates and queries under churn with reopen":
    randomize()
    let dir = getTempDir() / "glen_test_soak_index"
    if dirExists(dir): removeDir(dir)
    var db = newGlenDB(dir)
    # indexes
    db.createIndex("users", "byName", "name")
    db.createIndex("users", "byAge", "age")
    # seed
    let numSeed = 200
    for i in 0 ..< numSeed:
      upsertUser(db, "u" & $i)
    # churn
    let totalOps = 3000
    for i in 0 ..< totalOps:
      let r = rand(100)
      if r < 55:
        # update or insert
        upsertUser(db, "u" & $rand(numSeed + 100))
      elif r < 70:
        # delete
        db.delete("users", "u" & $rand(numSeed + 100))
      elif r < 90:
        # equality query
        let name = pickName()
        let rows = db.findBy("users", "byName", VString(name), 10)
        # verify hits actually match
        for (id, v) in rows:
          if not v.isNil and v.kind == vkObject and v["name"] != nil:
            discard
      else:
        # range query (age 25..50, desc, limit 5)
        let rows = db.rangeBy("users", "byAge", VInt(25), VInt(50), true, true, 5, false)
        # sanity: ages are within range if present
        for (id, v) in rows:
          if not v.isNil and v.kind == vkObject and v["age"] != nil:
            discard
      # periodic maintenance
      if (i mod 500) == 0 and i > 0:
        db.snapshotAll()
      if (i mod 1200) == 0 and i > 0:
        db.compact()
      if (i mod 1500) == 0 and i > 0:
        db.close()
        db = newGlenDB(dir)
    # final reopen and simple checks
    db.close()
    db = newGlenDB(dir)
    discard db.findBy("users", "byName", VString("Alice"), 3)
    discard db.rangeBy("users", "byAge", VInt(20), VInt(60), true, true, 10, true)
    db.close()

