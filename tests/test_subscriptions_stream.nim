import std/[unittest, streams, os]
import glen/glen

suite "subscriptions streaming":
  test "subscribeStream writes framed events":
    let dir = getTempDir() / "glen_test_sub_stream"
    if dirExists(dir): removeDir(dir)
    let db = newGlenDB(dir)
    defer: db.close()
    var ss = newStringStream()
    let h = db.subscribeStream("users", "u1", ss)
    db.put("users", "u1", VString("hi"))
    ss.setPosition(0)
    let ev = decodeFrom(ss)
    check ev.kind == vkObject
    check ev.getStrict("collection").s == "users"
    check ev.getStrict("docId").s == "u1"
    check ev.getStrict("value").s == "hi"
    db.unsubscribe(h)


