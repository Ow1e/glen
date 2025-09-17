# Glen Write-Ahead Log
# Simple segmented append log: glen.wal.0, glen.wal.1, ...
# Each record: varuint length | uint32 checksum(fnv1a of body) | body
# Body layout: varuint recordType | collection | docId | version | valueLen(+value)
# recordType: 1 = Put {collection, id, version, value}; 2 = Delete {collection,id,version}

import std/[os, streams]
when defined(windows):
  import std/winlean
import glen/types, glen/codec

const WAL_PREFIX = "glen.wal."
const WAL_MAGIC = "GLENWAL1"
const WAL_VERSION = 1'u32

type
  WalRecordType* = enum wrPut = 1, wrDelete = 2

  WalRecord* = object
    kind*: WalRecordType
    collection*: string
    docId*: string
    version*: uint64
    value*: Value  # only for put

  WriteAheadLog* = ref object
    dir*: string
    maxSegmentSize*: int
    currentIndex: int
    currentSize: int
    fs: File

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
    
  while true:
    let b = s.readUint8()
    result = result or (uint64(b and 0x7F) shl shift)
    if (b and 0x80) == 0: break
    shift += 7

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

proc openWriteAheadLog*(dir: string; maxSegmentSize = 8 * 1024 * 1024): WriteAheadLog =
  createDir(dir)
  result = WriteAheadLog(dir: dir, maxSegmentSize: maxSegmentSize)
  # find last segment
  var idx = 0
  while fileExists(segmentPath(dir, idx + 1)): inc idx
  result.currentIndex = idx
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
    try:
      let f = open(path, fmRead)
      sum += int(f.getFileSize())
      f.close()
    except IOError:
      discard
    inc idx
  sum

proc append*(wal: WriteAheadLog; rec: WalRecord) =
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

  let body = ms.data
  let crc = fnv1a32(body)
  var header = newStringStream()
  writeVarUint(header, uint64(body.len))
  let headerStr = header.data
  # include 4 bytes for checksum
  wal.rotateIfNeeded(headerStr.len + 4 + body.len)
  wal.fs.write(headerStr)
  # write checksum (little-endian)
  var cs = newStringStream()
  cs.write(crc)
  wal.fs.write(cs.data)
  wal.fs.write(body)
  wal.currentSize += headerStr.len + 4 + body.len
  wal.fs.flushFile()

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
    if ver != WAL_VERSION:
      f.close()
      inc idx
      continue
    var ok = true
    while not fs.atEnd:
      try:
        let recLen = readVarUint(fs)
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
        yield WalRecord(kind: rType, collection: collection, docId: docId, version: version, value: val)
      except IOError:
        ok = false
        break
    f.close()
    # proceed to next segment even if this one had tail corruption
    inc idx

proc close*(wal: WriteAheadLog) =
  if wal.fs != nil: wal.fs.close()
