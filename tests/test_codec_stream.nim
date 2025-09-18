import std/[unittest, streams]
import glen/glen

suite "codec streaming":
  test "encode/decode to/from stream":
    var ss = newStringStream()
    var obj = VObject()
    obj["a"] = VInt(42)
    obj["b"] = VString("hello")
    encodeTo(ss, VArray(@[obj, VBool(true)]))
    ss.setPosition(0)
    let round = decodeFrom(ss)
    check round.kind == vkArray
    let arr = round.arr
    check arr.len == 2
    check arr[0].kind == vkObject
    check arr[0].getStrict("a").i == 42
    check arr[0].getStrict("b").s == "hello"
    check arr[1] == VBool(true)


