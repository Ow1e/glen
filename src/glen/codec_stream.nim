import std/streams
import glen/types
import glen/codec
import glen/errors

proc writeVarUint(s: Stream; x: uint64) =
  var v = x
  while true:
    var b = uint8(v and 0x7F)
    v = v shr 7
    if v != 0: b = b or 0x80'u8
    s.write(b)
    if v == 0: break

proc readVarUint(s: Stream): uint64 =
  var shift: uint32 = 0
  var iterations = 0
  while true:
    let b = s.readUint8()
    result = result or (uint64(b and 0x7F) shl shift)
    if (b and 0x80) == 0: break
    shift += 7
    inc iterations
    if iterations > 10: raiseCodec("varuint too long")

proc encodeTo*(s: Stream; v: Value) =
  let data = encode(v)
  writeVarUint(s, uint64(data.len))
  s.write(data)

proc decodeFrom*(s: Stream): Value =
  if s.atEnd: raiseCodec("Unexpected EOF")
  let L = int(readVarUint(s))
  if L < 0: raiseCodec("negative length")
  let data = s.readStr(L)
  if data.len != L: raiseCodec("Unexpected EOF")
  result = decode(data)


