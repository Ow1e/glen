import std/[tables, sets, strutils, critbits]
import glen/types

type
  IndexSpec* = object
    name*: string
    fieldPaths*: seq[seq[string]]   ## each field path split into parts
    rangeable*: bool                ## true if single-field index supports range scans

  Index* = ref object
    spec*: IndexSpec
    ## key (serialized Value for equality/range) -> set of docIds
    map: Table[string, HashSet[string]]
    ## ordered set of keys for range and orderBy (lexicographic)
    keysTree: CritBitTree[bool]

  IndexesByName* = Table[string, Index]

proc serializePart(v: Value): string =
  if v.isNil: return "N|"
  case v.kind
  of vkNull: return "N|"
  of vkBool: return if v.b: "B|1" else: "B|0"
  of vkInt:
    ## lex-orderable signed int via biased uint64
    let u = uint64(v.i) + (1'u64 shl 63)
    return "I|" & toHex(u, 16)
  of vkFloat:
    ## Order-preserving float encoding: map to biased uint64 (IEEE754), fixed-width hex
    var bits = cast[uint64](v.f)
    if (bits and (1'u64 shl 63)) != 0: # negative
      bits = not bits
    else:
      bits = bits or (1'u64 shl 63)
    return "F|" & toHex(bits, 16)
  of vkString:
    return "S|" & v.s
  of vkBytes:
    ## Include content with length prefix encoded as hex (safe, order-preserving by content)
    var hex = newString(v.bytes.len * 2)
    var i = 0
    for b in v.bytes:
      let h = toHex(ord(b), 2)
      hex[i] = h[0]
      hex[i+1] = h[1]
      i += 2
    return "Y|" & $v.bytes.len & "|" & hex
  of vkArray:
    ## Serialize each part recursively for stable composite ordering
    var parts: seq[string] = @[]
    for it in v.arr:
      parts.add(serializePart(it))
    return "A|" & parts.join("\x1E")
  of vkObject:
    ## Objects are not orderable by default; use field count marker
    return "O|" & $v.obj.len
  of vkId:
    return "D|" & v.id.collection & ":" & v.id.docId

proc serializeKey*(v: Value): string =
  ## Serialize value (or array of values) into a composite key string
  if v.isNil: return serializePart(v)
  if v.kind == vkArray:
    var parts: seq[string] = @[]
    for it in v.arr:
      parts.add(serializePart(it))
    return parts.join("\x1E")
  else:
    return serializePart(v)

proc newIndex*(name: string; fieldExpr: string): Index =
  ## fieldExpr: comma-separated paths, e.g., "name" or "name,profile.age"
  var paths: seq[seq[string]] = @[]
  for raw in fieldExpr.split(','):
    let trimmed = raw.strip()
    if trimmed.len > 0:
      paths.add(trimmed.split('.'))
  let rangeable = paths.len == 1
  Index(spec: IndexSpec(name: name, fieldPaths: paths, rangeable: rangeable), map: initTable[string, HashSet[string]](), keysTree: CritBitTree[bool]())

proc extractField*(doc: Value; path: seq[string]): Value =
  var cur = doc
  for p in path:
    if cur.isNil or cur.kind != vkObject: return nil
    cur = cur[p]
  return cur

proc extractComposite*(doc: Value; paths: seq[seq[string]]): Value =
  if paths.len == 1:
    return extractField(doc, paths[0])
  var parts: seq[Value] = @[]
  for p in paths:
    parts.add(extractField(doc, p))
  return VArray(parts)

proc addKey(i: Index; key: string; docId: string) =
  if key notin i.map:
    i.map[key] = initHashSet[string]()
    i.keysTree[key] = true
  i.map[key].incl(docId)

proc removeKey(i: Index; key: string; docId: string) =
  if key in i.map:
    i.map[key].excl(docId)
    if i.map[key].len == 0:
      i.map.del(key)
      # rebuild keys tree from remaining keys
      var rebuilt: CritBitTree[bool]
      for k, _ in i.map.pairs:
        rebuilt[k] = true
      i.keysTree = rebuilt

proc indexDoc*(i: Index; docId: string; doc: Value) =
  if doc.isNil: return
  let v = extractComposite(doc, i.spec.fieldPaths)
  let key = serializeKey(v)
  i.addKey(key, docId)

proc unindexDoc*(i: Index; docId: string; doc: Value) =
  if doc.isNil: return
  let v = extractComposite(doc, i.spec.fieldPaths)
  let key = serializeKey(v)
  i.removeKey(key, docId)

proc reindexDoc*(i: Index; docId: string; oldDoc, newDoc: Value) =
  if not oldDoc.isNil: i.unindexDoc(docId, oldDoc)
  if not newDoc.isNil: i.indexDoc(docId, newDoc)

proc findEq*(i: Index; keyValue: Value; limit = 0): seq[string] =
  ## Return matching docIds for equality on the indexed field.
  let k = serializeKey(keyValue)
  if k in i.map:
    result = @[]
    for id in i.map[k].items:
      result.add(id)
      if limit > 0 and result.len >= limit: break

proc findRange*(i: Index; minVal: Value; maxVal: Value; inclusiveMin = true; inclusiveMax = true; limit = 0; asc = true): seq[string] =
  ## Range scan over a single-field index. For composite indexes this returns empty.
  if not i.spec.rangeable: return @[]
  let minK = if minVal.isNil: "" else: serializeKey(minVal)
  let maxK = if maxVal.isNil: "\xFF".repeat(8) else: serializeKey(maxVal)
  result = @[]
  if asc:
    for k, _ in i.keysTree.pairs:
      if (k > minK or (inclusiveMin and k == minK)) and (k < maxK or (inclusiveMax and k == maxK)):
        for id in i.map[k].items:
          result.add(id)
          if limit > 0 and result.len >= limit: return
  else:
    var tmpKeys: seq[string] = @[]
    for k, _ in i.keysTree.pairs:
      tmpKeys.add(k)
    var idx = tmpKeys.len - 1
    while idx >= 0:
      let k = tmpKeys[idx]
      if (k < maxK or (inclusiveMax and k == maxK)) and (k > minK or (inclusiveMin and k == minK)):
        for id in i.map[k].items:
          result.add(id)
          if limit > 0 and result.len >= limit: return
      if idx == 0: break
      dec idx


