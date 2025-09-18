import std/os
import std/unittest
import glen/db, glen/types, glen/txn
import std/options

suite "basic db ops":
  test "put get":
    let dir = getTempDir() / "glen_test_db"
    let db = newGlenDB(dir)
    let v = VObject()
    v["name"] = VString("Bob")
    db.put("people", "p1", v)
    check not db.get("people", "p1").isNil
  
  test "delete":
    let dir = getTempDir() / "glen_test_db2"
    let db = newGlenDB(dir)
    let v = VObject(); db.put("people", "p2", v)
    db.delete("people", "p2")
    check db.get("people", "p2").isNil
  
  test "transaction commit and conflict":
    let dir = getTempDir() / "glen_test_db3"
    let db = newGlenDB(dir)
    var v = VObject(); v["n"] = VString("one")
    db.put("items", "i1", v)
    let t1 = db.beginTxn()
    discard db.get("items", "i1", t1)
    var v2 = VObject(); v2["n"] = VString("two")
    db.put("items", "i1", v2)
    var v3 = VObject(); v3["n"] = VString("three")
    t1.stagePut(Id(collection: "items", docId: "i1", version: db.currentVersion("items", "i1")), v3)
    let res = db.commit(t1)
    check res.status == csConflict

  test "transaction success path":
    let dir = getTempDir() / "glen_test_txn_success"
    let db = newGlenDB(dir)
    db.put("t", "1", VString("old"))
    let t = db.beginTxn()
    discard db.get("t", "1", t)
    t.stagePut(Id(collection: "t", docId: "1", version: db.currentVersion("t", "1")), VString("new"))
    let res = db.commit(t)
    check res.ok
    check $db.get("t", "1") == "\"new\""

  test "value safe getters and typed opts":
    var o = VObject()
    o["b"] = VBool(true)
    o["n"] = VInt(7)
    o["s"] = VString("x")
    check o.isObject
    check o.hasKey("b")
    check not o.hasKey("missing")
    check o.getOrNil("missing").isNil
    check o.getOrDefault("missing", VString("def")).toStringOpt().get() == "def"
    check o["b"].toBoolOpt().get() == true
    check o["n"].toIntOpt().get() == 7
    check o["s"].toStringOpt().get() == "x"
    check o.getOpt("n").isSome

  test "index create, query, and drop":
    let dir = getTempDir() / "glen_test_idx"
    let db = newGlenDB(dir)
    var u1 = VObject(); u1["name"] = VString("Alice"); db.put("users", "1", u1)
    var u2 = VObject(); u2["name"] = VString("Bob"); db.put("users", "2", u2)
    var u3 = VObject(); u3["name"] = VString("Alice"); db.put("users", "3", u3)
    db.createIndex("users", "byName", "name")
    let rows = db.findBy("users", "byName", VString("Alice"))
    # Expect ids 1 and 3 in any order
    var ids: seq[string] = @[]
    for row in rows: ids.add(row[0])
    check ids.len == 2
    check ("1" in ids) and ("3" in ids)
    db.dropIndex("users", "byName")

  test "composite index equality and range order":
    let dir = getTempDir() / "glen_test_idx2"
    let db = newGlenDB(dir)
    var u1 = VObject(); u1["name"] = VString("Alice"); u1["age"] = VInt(30); db.put("users", "1", u1)
    var u2 = VObject(); u2["name"] = VString("Bob"); u2["age"] = VInt(25); db.put("users", "2", u2)
    var u3 = VObject(); u3["name"] = VString("Alice"); u3["age"] = VInt(35); db.put("users", "3", u3)
    db.createIndex("users", "byNameAge", "name,age")
    let eqRows = db.findBy("users", "byNameAge", VArray(@[VString("Alice"), VInt(30)]))
    check eqRows.len == 1 and eqRows[0][0] == "1"
    db.createIndex("users", "byAge", "age")
    let ascRows = db.rangeBy("users", "byAge", VInt(26), VInt(40), true, true, 0, true)
    var ascIds: seq[string] = @[]
    for row in ascRows: ascIds.add(row[0])
    check ascIds == @["1", "3"]
    let descRows = db.rangeBy("users", "byAge", VInt(0), VInt(40), true, true, 2, false)
    var descIds: seq[string] = @[]
    for row in descRows: descIds.add(row[0])
    check descIds == @["3", "1"]

  test "batch getMany and getAll":
    let dir = getTempDir() / "glen_test_batch"
    let db = newGlenDB(dir)
    var u1 = VObject(); u1["name"] = VString("A"); db.put("users", "1", u1)
    var u2 = VObject(); u2["name"] = VString("B"); db.put("users", "2", u2)
    var u3 = VObject(); u3["name"] = VString("C"); db.put("users", "3", u3)
    let many = db.getMany("users", ["1", "3", "x"])  # includes a missing id
    var ids: seq[string] = @[]
    for (id, _) in many: ids.add(id)
    check ids.len == 2
    check ("1" in ids) and ("3" in ids)
    let allRows = db.getAll("users")
    check allRows.len == 3