import std/unittest
import glen/cache
import glen/types

suite "cache behavior":
  test "eviction under capacity pressure":
    var c = newLruCache(64)
    c.put("k1", VString("aaaaaaaaaa"))
    c.put("k2", VString("bbbbbbbbbb"))
    c.put("k3", VString("cccccccccc"))
    discard c.get("k3")
    c.put("k4", VString("dddddddddd"))
    let g1 = c.get("k1")
    let g3 = c.get("k3")
    check g1.isNil
    check not g3.isNil
