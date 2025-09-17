import std/[tables, sets, strutils]
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
    ## sorted list of keys for range and orderBy
    keys: seq[string]

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
    ## approximate ordering by formatting
    return "F|" & $v.f
  of vkString:
    return "S|" & v.s
  of vkBytes:
    return "Y|" & $v.bytes.len
  of vkArray:
    return "A|" & $v.arr.len
  of vkObject:
    return "O|"
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
  Index(spec: IndexSpec(name: name, fieldPaths: paths, rangeable: rangeable), map: initTable[string, HashSet[string]](), keys: @[])

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
    ## insert key in sorted order
    var lo = 0
    var hi = i.keys.len
    while lo < hi:
      let mid = (lo + hi) div 2
      if i.keys[mid] < key: lo = mid + 1 else: hi = mid
    i.keys.insert(key, lo)
  i.map[key].incl(docId)

proc removeKey(i: Index; key: string; docId: string) =
  if key in i.map:
    i.map[key].excl(docId)
    if i.map[key].len == 0:
      i.map.del(key)
      ## remove from sorted keys
      var lo = 0
      var hi = i.keys.len
      while lo < hi:
        let mid = (lo + hi) div 2
        if i.keys[mid] < key: lo = mid + 1 else: hi = mid
      if lo < i.keys.len and i.keys[lo] == key:
        i.keys.delete(lo)

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
    for k in i.keys:
      if (k > minK or (inclusiveMin and k == minK)) and (k < maxK or (inclusiveMax and k == maxK)):
        for id in i.map[k].items:
          result.add(id)
          if limit > 0 and result.len >= limit: return
  else:
    var idx = i.keys.len - 1
    while idx >= 0:
      let k = i.keys[idx]
      if (k < maxK or (inclusiveMax and k == maxK)) and (k > minK or (inclusiveMin and k == minK)):
        for id in i.map[k].items:
          result.add(id)
          if limit > 0 and result.len >= limit: return
      if idx == 0: break
      dec idx


