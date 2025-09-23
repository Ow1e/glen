import std/os
import std/unittest
import glen/types
import glen/db
import glen/wal

proc cleanDir(dir: string) =
  if dirExists(dir): removeDir(dir)

suite "multi-master replication":
  test "export/apply basic and idempotency":
    let dirA = getTempDir() / "glen_mm_a"
    let dirB = getTempDir() / "glen_mm_b"
    cleanDir(dirA); cleanDir(dirB)
    let a = newGlenDB(dirA)
    let b = newGlenDB(dirB)
    # Local writes on A
    a.put("users", "u1", VString("alice"))
    a.put("users", "u2", VString("bob"))
    # Export from A and apply to B
    var cursor: ReplExportCursor = 0'u64
    let (c1, ch) = a.exportChanges(cursor)
    check ch.len == 2
    b.applyChanges(ch)
    # Idempotent re-apply
    b.applyChanges(ch)
    # Verify
    check b.get("users", "u1") == VString("alice")
    check b.get("users", "u2") == VString("bob")
    cursor = c1
    discard cursor

  test "LWW conflict convergence":
    let dirA = getTempDir() / "glen_mm_lww_a"
    let dirB = getTempDir() / "glen_mm_lww_b"
    cleanDir(dirA); cleanDir(dirB)
    let a = newGlenDB(dirA)
    let b = newGlenDB(dirB)
    # Start with same doc id, divergent writes
    a.put("items", "i1", VString("a1"))
    b.put("items", "i1", VString("b1"))
    # Exchange changes both ways
    var ca: ReplExportCursor = 0'u64
    var cb: ReplExportCursor = 0'u64
    let (ca2, cha) = a.exportChanges(ca)
    let (cb2, chb) = b.exportChanges(cb)
    b.applyChanges(cha)
    a.applyChanges(chb)
    # Converge with repeated exchanges until no more changes
    var iter = 0
    var ca3 = ca2
    var cb3 = cb2
    while iter < 3:
      let (nca, na) = a.exportChanges(ca3)
      let (ncb, nb) = b.exportChanges(cb3)
      if na.len == 0 and nb.len == 0: break
      b.applyChanges(na)
      a.applyChanges(nb)
      ca3 = nca; cb3 = ncb; inc iter
    # Both sides should end up with the same value
    let va = a.get("items", "i1")
    let vb = b.get("items", "i1")
    check not va.isNil and not vb.isNil
    check va == vb

  test "durability: apply then reopen persists":
    let dirA = getTempDir() / "glen_mm_dur_a"
    let dirB = getTempDir() / "glen_mm_dur_b"
    cleanDir(dirA); cleanDir(dirB)
    var a = newGlenDB(dirA)
    var b = newGlenDB(dirB)
    a.put("c", "x", VString("1"))
    let (_, ch) = a.exportChanges(0'u64)
    b.applyChanges(ch)
    # Ensure persistence before reopen
    b.compact()
    # Close and reopen B; expect data still there
    b.close()
    b = newGlenDB(dirB)
    check b.get("c", "x") == VString("1")

  test "export filters include/exclude":
    let dirA = getTempDir() / "glen_mm_filter_a"
    cleanDir(dirA)
    let a = newGlenDB(dirA)
    a.put("users", "u1", VString("x"))
    a.put("posts", "p1", VString("y"))
    let (_, all) = a.exportChanges(0'u64)
    check all.len == 2
    let (_, onlyUsers) = a.exportChanges(0'u64, includeCollections = @["users"])
    check onlyUsers.len == 1 and onlyUsers[0].collection == "users"
    let (_, noPosts) = a.exportChanges(0'u64, excludeCollections = @["posts"])
    check noPosts.len == 1 and noPosts[0].collection == "users"


