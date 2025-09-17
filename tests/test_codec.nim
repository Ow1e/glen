import std/unittest
import std/random
import std/tables
import glen/codec
import glen/types
import glen/storage
import std/os

proc genVal(depth: int): Value =
  if depth <= 0:
    case rand(5)
    of 0: return VNull()
    of 1: return VBool(rand(2) == 1)
    of 2: return VInt(rand(1000).int64)
    of 3: return VFloat(rand(1000).float)
    else: return VString("s" & $rand(10000))
  else:
    case rand(7)
    of 0: return genVal(0)
    of 1: return VBytes(@[byte(rand(255))])
    of 2:
      var items: seq[Value] = @[]
      let n = rand(3)
      for i in 0..n: items.add(genVal(depth-1))
      return VArray(items)
    of 3:
      var o = VObject()
      let n = rand(3)
      for i in 0..n:
        o["k" & $i] = genVal(depth-1)
      return o
    of 4: return VId("c", "d" & $rand(100), uint64(rand(10)))
    of 5: return VBool(rand(2) == 1)
    else: return VString("t" & $rand(1000))

suite "codec fuzz":
  test "encode/decode round-trip fuzz":
    randomize()
    for i in 0..100:
      let v = genVal(3)
      let enc = encode(v)
      let dec = decode(enc)
      check v == dec

  test "snapshot round-trip fuzz":
    randomize()
    let dir = getTempDir() / "glen_test_snap_fuzz"
    var docs: Table[string, Value]
    for i in 0..20:
      docs["id" & $i] = genVal(2)
    writeSnapshot(dir, "col", docs)
    let loaded = loadSnapshot(dir, "col")
    check loaded.len == docs.len
    for k, v in docs:
      check k in loaded
      check v == loaded[k]
