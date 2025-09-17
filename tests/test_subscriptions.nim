import std/os
import std/unittest
import std/strutils
import glen/db, glen/types, glen/txn

suite "subscriptions and transactions":
  test "subscribe receives put/delete and transactional writes":
    let dir = getTempDir() / "glen_test_subs"
    let db = newGlenDB(dir)
    var events: seq[string] = @[]
    let h1 = db.subscribe("c", "d", proc(id: Id; v: Value) =
      events.add($id & "|" & $v)
    )
    let h2 = db.subscribe("c", "e", proc(id: Id; v: Value) =
      events.add($id & "|" & $v)
    )
    db.put("c", "d", VString("v1"))
    db.delete("c", "d")
    let t = db.beginTxn()
    t.stagePut(Id(collection: "c", docId: "e", version: 0'u64), VString("txn"))
    discard db.commit(t)
    db.unsubscribe(h1)
    db.unsubscribe(h2)
    var sawPutD = false
    var sawDelD = false
    for ev in events:
      if ev.contains("c:d@1") and ev.contains("\"v1\""): sawPutD = true
      if ev.contains("c:d@2") and ev.contains("null"): sawDelD = true
    check sawPutD and sawDelD
    check $db.get("c", "e") == "\"txn\""
