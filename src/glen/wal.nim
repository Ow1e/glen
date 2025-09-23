# Glen Write-Ahead Log
# Simple segmented append log: glen.wal.0, glen.wal.1, ...
# Each record: varuint length | uint32 checksum(fnv1a of body) | body
# Body layout: varuint recordType | collection | docId | version | valueLen(+value)
# recordType: 1 = Put {collection, id, version, value}; 2 = Delete {collection,id,version}

import std/[os, streams, locks]
when defined(windows):
  import std/winlean
import glen/types, glen/codec

const WAL_PREFIX = "glen.wal."
const WAL_MAGIC = "GLENWAL1"
const WAL_VERSION = 2'u32
const MAX_WAL_RECORD_SIZE = 64 * 1024 * 1024  # 64 MiB safety cap

type
  WalRecordType* = enum wrPut = 1, wrDelete = 2

  WalSyncMode* = enum wsmAlways, wsmInterval, wsmNone

  WalRecord* = object
    kind*: WalRecordType
    collection*: string
    docId*: string
    version*: uint64
    value*: Value  # only for put
    # Replication metadata (v2+). Optional when reading v1 segments.
    changeId*: string
    originNode*: string
    hlc*: Hlc

  WriteAheadLog* = ref object
    dir*: string
    maxSegmentSize*: int
    currentIndex: int
    currentSize: int
    fs: File
    syncMode: WalSyncMode
    flushEveryBytes: int
    bytesSinceFlush: int
    lock: Lock

proc fnv1a32(data: string): uint32 =
  var h: uint32 = 0x811C9DC5'u32
  for ch in data:
    h = h xor uint32(uint8(ch))
    h = h * 0x01000193'u32
  h

proc writeVarUint(s: Stream; x: uint64) =
  var v = x
  while true:
    var b = uint8(v and 0x7F)
    v = v shr 7
    if v != 0: b = b or 0x80'u8
    s.write(b)
    if v == 0: break

proc readVarUint(s: Stream): uint64 =
  var shift: uint32
  var iterations = 0
  while true:
    let b = s.readUint8()
    result = result or (uint64(b and 0x7F) shl shift)
    if (b and 0x80) == 0: break
    shift += 7
    inc iterations
    if iterations > 10: raise newException(IOError, "varuint too long")

proc segmentPath(dir: string; idx: int): string =
  dir / (WAL_PREFIX & $idx)

proc flushDir(dir: string) =
  when defined(windows):
    let w = newWideCString(dir)
    let h = createFileW(w, GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0)
    if h != INVALID_HANDLE_VALUE:
      discard flushFileBuffers(h)
      discard closeHandle(h)
  else:
    discard

proc openSegment(wal: WriteAheadLog) =
  if wal.fs != nil:
    wal.fs.flushFile()
    wal.fs.close()
    wal.fs = nil
  wal.fs = open(segmentPath(wal.dir, wal.currentIndex), fmAppend)
  if wal.fs.getFileSize == 0:
    # new file: write magic + version header
    var hs = newStringStream()
    hs.write(WAL_MAGIC)
    hs.write(WAL_VERSION)
    wal.fs.write(hs.data)
    wal.fs.flushFile()
    flushDir(wal.dir)
  wal.currentSize = int(wal.fs.getFileSize())

proc openWriteAheadLog*(dir: string; maxSegmentSize = 8 * 1024 * 1024; syncMode: WalSyncMode = wsmAlways; flushEveryBytes = 1 * 1024 * 1024): WriteAheadLog =
  createDir(dir)
  result = WriteAheadLog(dir: dir, maxSegmentSize: maxSegmentSize, syncMode: syncMode, flushEveryBytes: flushEveryBytes, bytesSinceFlush: 0)
  initLock(result.lock)
  # find last segment
  var idx = 0
  while fileExists(segmentPath(dir, idx + 1)): inc idx
  result.currentIndex = idx
  # If existing last segment has older header version, start a new segment to upgrade
  if fileExists(segmentPath(dir, idx)):
    try:
      let f = open(segmentPath(dir, idx), fmRead)
      let fs = newFileStream(f)
      let magic = fs.readStr(WAL_MAGIC.len)
      if magic == WAL_MAGIC:
        let ver = fs.readUint32()
        if ver != WAL_VERSION:
          result.currentIndex = idx + 1
      fs.close(); f.close()
    except IOError:
      discard
  result.openSegment()

proc rotateIfNeeded(wal: WriteAheadLog; needed: int) =
  if wal.currentSize + needed > wal.maxSegmentSize:
    inc wal.currentIndex
    wal.openSegment()

proc size*(wal: WriteAheadLog): int = wal.currentSize

proc reset*(wal: WriteAheadLog) =
  if wal.fs != nil:
    wal.fs.flushFile()
    wal.fs.close()
    wal.fs = nil
  var idx = 0
  while true:
    let path = segmentPath(wal.dir, idx)
    if not fileExists(path): break
    removeFile(path)
    inc idx
  wal.currentIndex = 0
  wal.openSegment()

proc totalSize*(wal: WriteAheadLog): int =
  var idx = 0
  var sum = 0
  while true:
    let path = segmentPath(wal.dir, idx)
    if not fileExists(path): break
    if idx == wal.currentIndex:
      sum += wal.currentSize
    else:
      try:
        let f = open(path, fmRead)
        sum += int(f.getFileSize())
        f.close()
      except IOError:
        discard
    inc idx
  sum

proc flush*(wal: WriteAheadLog) =
  ## Force flush the current WAL file to disk regardless of sync policy.
  acquire(wal.lock)
  defer: release(wal.lock)
  if wal.fs != nil:
    wal.fs.flushFile()

proc append*(wal: WriteAheadLog; rec: WalRecord) =
  acquire(wal.lock)
  defer: release(wal.lock)
  var ms = newStringStream()
  # recordType
  writeVarUint(ms, uint64(rec.kind.ord))
  # collection
  writeVarUint(ms, uint64(rec.collection.len)); ms.write(rec.collection)
  # docId
  writeVarUint(ms, uint64(rec.docId.len)); ms.write(rec.docId)
  # version
  ms.write(rec.version)
  # value if put (optional compression could be inserted here in future)
  if rec.kind == wrPut:
    let payload = encode(rec.value)
    writeVarUint(ms, uint64(payload.len))
    ms.write(payload)
  else:
    writeVarUint(ms, 0) # zero length
  # Replication metadata (v2+): write strings and HLC
  writeVarUint(ms, uint64(rec.changeId.len)); if rec.changeId.len > 0: ms.write(rec.changeId)
  writeVarUint(ms, uint64(rec.originNode.len)); if rec.originNode.len > 0: ms.write(rec.originNode)
  ms.write(rec.hlc.wallMillis)
  ms.write(rec.hlc.counter)
  writeVarUint(ms, uint64(rec.hlc.nodeId.len)); if rec.hlc.nodeId.len > 0: ms.write(rec.hlc.nodeId)

  let body = ms.data
  let crc = fnv1a32(body)
  var header = newStringStream()
  writeVarUint(header, uint64(body.len))
  let headerStr = header.data
  # include 4 bytes for checksum
  wal.rotateIfNeeded(headerStr.len + 4 + body.len)
  wal.fs.write(headerStr)
  # write checksum (little-endian) without extra allocation
  var csBuf: array[4, byte]
  csBuf[0] = byte(crc and 0xFF)
  csBuf[1] = byte((crc shr 8) and 0xFF)
  csBuf[2] = byte((crc shr 16) and 0xFF)
  csBuf[3] = byte((crc shr 24) and 0xFF)
  discard wal.fs.writeBuffer(addr csBuf[0], 4)
  wal.fs.write(body)
  wal.currentSize += headerStr.len + 4 + body.len
  let written = headerStr.len + 4 + body.len
  case wal.syncMode
  of wsmAlways:
    wal.fs.flushFile()
    wal.bytesSinceFlush = 0
  of wsmInterval:
    wal.bytesSinceFlush += written
    if wal.bytesSinceFlush >= wal.flushEveryBytes:
      wal.fs.flushFile()
      wal.bytesSinceFlush = 0
  of wsmNone:
    discard

proc appendMany*(wal: WriteAheadLog; recs: openArray[WalRecord]) =
  acquire(wal.lock)
  defer: release(wal.lock)
  var totalWritten = 0
  for rec in recs:
    var ms = newStringStream()
    writeVarUint(ms, uint64(rec.kind.ord))
    writeVarUint(ms, uint64(rec.collection.len)); ms.write(rec.collection)
    writeVarUint(ms, uint64(rec.docId.len)); ms.write(rec.docId)
    ms.write(rec.version)
    if rec.kind == wrPut:
      let payload = encode(rec.value)
      writeVarUint(ms, uint64(payload.len))
      ms.write(payload)
    else:
      writeVarUint(ms, 0)
    # Replication metadata (v2+)
    writeVarUint(ms, uint64(rec.changeId.len)); if rec.changeId.len > 0: ms.write(rec.changeId)
    writeVarUint(ms, uint64(rec.originNode.len)); if rec.originNode.len > 0: ms.write(rec.originNode)
    ms.write(rec.hlc.wallMillis)
    ms.write(rec.hlc.counter)
    writeVarUint(ms, uint64(rec.hlc.nodeId.len)); if rec.hlc.nodeId.len > 0: ms.write(rec.hlc.nodeId)

    let body = ms.data
    let crc = fnv1a32(body)
    var header = newStringStream()
    writeVarUint(header, uint64(body.len))
    let headerStr = header.data
    wal.rotateIfNeeded(headerStr.len + 4 + body.len)
    wal.fs.write(headerStr)
    var csBuf: array[4, byte]
    csBuf[0] = byte(crc and 0xFF)
    csBuf[1] = byte((crc shr 8) and 0xFF)
    csBuf[2] = byte((crc shr 16) and 0xFF)
    csBuf[3] = byte((crc shr 24) and 0xFF)
    discard wal.fs.writeBuffer(addr csBuf[0], 4)
    wal.fs.write(body)
    wal.currentSize += headerStr.len + 4 + body.len
    totalWritten += headerStr.len + 4 + body.len

  case wal.syncMode
  of wsmAlways:
    wal.fs.flushFile()
    wal.bytesSinceFlush = 0
  of wsmInterval:
    wal.bytesSinceFlush += totalWritten
    if wal.bytesSinceFlush >= wal.flushEveryBytes:
      wal.fs.flushFile()
      wal.bytesSinceFlush = 0
  of wsmNone:
    discard

iterator replay*(dir: string): WalRecord =
  var idx = 0
  while true:
    let path = segmentPath(dir, idx)
    if not fileExists(path): break
    var f = open(path, fmRead)
    var fs = newFileStream(f)
    # Validate segment header
    let magic = fs.readStr(WAL_MAGIC.len)
    if magic != WAL_MAGIC:
      f.close()
      inc idx
      continue
    let ver = fs.readUint32()
    # Support v1 (legacy) and v2 (current). Skip unknown versions.
    if ver != 1'u32 and ver != 2'u32:
      f.close()
      inc idx
      continue
    var ok = true
    while not fs.atEnd:
      try:
        let recLen = readVarUint(fs)
        # Guard record size to avoid pathological allocations
        if recLen > uint64(MAX_WAL_RECORD_SIZE):
          ok = false
          break
        let crcOnDisk = fs.readUint32()
        let body = if recLen > 0: fs.readStr(int(recLen)) else: ""
        if fnv1a32(body) != crcOnDisk:
          ok = false
          break
        var rs = newStringStream(body)
        let rType = WalRecordType(readVarUint(rs).int)
        let clen = int(readVarUint(rs)); let collection = rs.readStr(clen)
        let dlen = int(readVarUint(rs)); let docId = rs.readStr(dlen)
        let version = rs.readUint64()
        let vlen = int(readVarUint(rs))
        var val: Value
        if rType == wrPut and vlen > 0:
          let enc = rs.readStr(vlen)
          val = decode(enc)
        if ver == 1'u32:
          yield WalRecord(kind: rType, collection: collection, docId: docId, version: version, value: val)
        else:
          # v2: read replication metadata
          let cidLen = int(readVarUint(rs)); let changeId = if cidLen > 0: rs.readStr(cidLen) else: ""
          let onLen = int(readVarUint(rs)); let originNode = if onLen > 0: rs.readStr(onLen) else: ""
          let wall = rs.readInt64()
          let ctr = rs.readUint32()
          let hnLen = int(readVarUint(rs)); let hlcNode = if hnLen > 0: rs.readStr(hnLen) else: ""
          let rec = WalRecord(kind: rType, collection: collection, docId: docId, version: version, value: val, changeId: changeId, originNode: originNode, hlc: Hlc(wallMillis: wall, counter: ctr, nodeId: hlcNode))
          yield rec
      except IOError:
        ok = false
        break
    f.close()
    # proceed to next segment even if this one had tail corruption
    inc idx

proc close*(wal: WriteAheadLog) =
  if wal.fs != nil:
    wal.fs.close()
    wal.fs = nil

proc setSyncPolicy*(wal: WriteAheadLog; mode: WalSyncMode; flushEveryBytes = 0) =
  wal.syncMode = mode
  if mode == wsmInterval and flushEveryBytes > 0:
    wal.flushEveryBytes = flushEveryBytes
