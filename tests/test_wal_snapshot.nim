import std/os
import std/unittest
import std/tables
import glen/wal, glen/storage
import glen/types
import glen/db

suite "wal and snapshot tests":
  test "wal replay tolerates corrupt tail":
    let dir = getTempDir() / "glen_test_wal"
    if dirExists(dir): removeDir(dir)
    let w = openWriteAheadLog(dir)
    let v1 = VString("one")
    w.append(WalRecord(kind: wrPut, collection: "x", docId: "a", version: 1'u64, value: v1, changeId: "1:test", originNode: "test", hlc: Hlc(wallMillis: 1'i64, counter: 0'u32, nodeId: "test")))
    let v2 = VString("two")
    w.append(WalRecord(kind: wrPut, collection: "x", docId: "b", version: 1'u64, value: v2, changeId: "2:test", originNode: "test", hlc: Hlc(wallMillis: 2'i64, counter: 0'u32, nodeId: "test")))
    w.close()
    let walPath = dir / "glen.wal.0"
    var data = readFile(walPath)
    if data.len > 3:
      writeFile(walPath, data[0 ..< data.len - 3])
    var count = 0
    var last: WalRecord
    for rec in replay(dir):
      inc count
      last = rec
    check count == 1
    check last.collection == "x" and last.docId == "a"

  test "snapshot round-trip":
    let dir = getTempDir() / "glen_test_snap"
    var docs: Table[string, Value]
    docs["a"] = VString("alpha")
    var o = VObject(); o["n"] = VInt(42); docs["b"] = o
    writeSnapshot(dir, "col", docs)
    let loaded = loadSnapshot(dir, "col")
    check loaded.len == docs.len
    for k, v in docs:
      check k in loaded
      check loaded[k] == v

  test "compaction truncates WAL after snapshot":
    let dir = getTempDir() / "glen_test_compact"
    if dirExists(dir): removeDir(dir)
    let db = newGlenDB(dir)
    db.put("c", "1", VString("v1"))
    db.put("c", "2", VString("v2"))
    let before = db.wal.totalSize()
    check before > 0
    db.compact()
    let after = db.wal.totalSize()
    check after > 0 # header exists
    check after < before
