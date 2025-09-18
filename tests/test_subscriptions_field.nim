import std/[unittest, streams, os]
import glen/glen

suite "field subscriptions":
  test "callback fires only on path change":
    let dir = getTempDir() / "glen_test_field_cb"
    if dirExists(dir): removeDir(dir)
    let db = newGlenDB(dir)
    defer: db.close()
    var hits = 0
    let h = db.subscribeField("users", "u1", "profile.age", proc(id: Id; path: string; oldV: Value; newV: Value) =
      inc hits
      check path == "profile.age"
    )
    var u = VObject(); var prof = VObject(); prof["age"] = VInt(30); u["profile"] = prof
    db.put("users", "u1", u)             # age: nil -> 30
    db.put("users", "u1", u)             # same value; no change
    prof["age"] = VInt(31); u["profile"] = prof
    db.put("users", "u1", u)             # age: 30 -> 31
    db.delete("users", "u1")              # age: 31 -> nil
    db.unsubscribeField(h)
    check hits == 3

  test "stream writes framed field events":
    let dir = getTempDir() / "glen_test_field_stream"
    if dirExists(dir): removeDir(dir)
    let db = newGlenDB(dir)
    defer: db.close()
    var ss = newStringStream()
    let hs = db.subscribeFieldStream("users", "u2", "name", ss)
    db.put("users", "u2", VObject())                # no "name" yet -> no event
    var u2 = VObject(); u2["name"] = VString("Alice")
    db.put("users", "u2", u2)                        # name: nil -> "Alice" => one event
    ss.setPosition(0)
    let ev = decodeFrom(ss)
    check ev.kind == vkObject
    check ev.getStrict("fieldPath").s == "name"
    check ev.getStrict("new").s == "Alice"
    db.unsubscribeField(hs)

  test "delta subscription reports append":
    let dir = getTempDir() / "glen_test_field_delta"
    if dirExists(dir): removeDir(dir)
    let db = newGlenDB(dir)
    defer: db.close()
    var gotAppend = false
    let hd = db.subscribeFieldDelta("logs", "d1", "text", proc(id: Id; path: string; delta: Value) =
      if delta.kind == vkObject and delta.getStrict("kind").s == "append":
        check delta.getStrict("added").s == " world"
        gotAppend = true
    )
    var o = VObject(); o["text"] = VString("hello")
    db.put("logs", "d1", o)
    o["text"] = VString("hello world")
    db.put("logs", "d1", o)
    db.unsubscribeFieldDelta(hd)
    check gotAppend


