# Glen DB high-level API

import std/[os, tables, locks, strutils, streams, hashes, algorithm, parseutils]
import glen/types, glen/wal, glen/storage, glen/cache, glen/subscription, glen/txn
import glen/rwlock
import glen/index
import glen/config
import glen/util
type
  ReplOp* = enum roPut, roDelete

  ReplChange* = object
    collection*: string
    docId*: string
    op*: ReplOp
    version*: uint64
    value*: Value
    changeId*: string
    originNode*: string
    hlc*: Hlc


# In-memory store: collection -> (docId -> Value)

type
  CollectionStore = Table[string, Value]

  GlenDB* = ref object
    dir*: string
    wal*: WriteAheadLog
    collections: Table[string, CollectionStore]
    versions: Table[string, Table[string, uint64]]  # collection -> docId -> version
    cache: LruCache
    subs: SubscriptionManager
    indexes: Table[string, IndexesByName]          # collection -> name -> Index
    lock: Lock
    rw: RwLock
    lockStripes: seq[RwLock]
    # Replication
    nodeId*: string
    replSeq: uint64
    # change log (in-memory): seq -> change
    replLog: seq[(uint64, ReplChange)]
    # last applied HLC per doc for conflict resolution
    replMetaHlc: Table[string, Table[string, Hlc]]
    # last applied changeId per doc for idempotency
    replMetaChangeId: Table[string, Table[string, string]]
    # local HLC state
    localHlc: Hlc
    # Replication peers cursors (peerId -> last exported/applied seq)
    peersCursors: Table[string, uint64]
    peersStatePath: string

## Create or open a Glen database at the given directory.
## Loads snapshots, replays the WAL, and initializes cache and subscriptions.
proc newGlenDB*(dir: string; cacheCapacity = 64*1024*1024; cacheShards = 16; walSync: WalSyncMode = wsmInterval; walFlushEveryBytes = 8*1024*1024; lockStripesCount = 32): GlenDB =
  result = GlenDB(
    dir: dir,
    wal: openWriteAheadLog(dir, syncMode = walSync, flushEveryBytes = walFlushEveryBytes),
    collections: initTable[string, CollectionStore](),
    versions: initTable[string, Table[string, uint64]](),
    cache: newLruCache(cacheCapacity, numShards = cacheShards),
    subs: newSubscriptionManager(),
    indexes: initTable[string, IndexesByName](),
    replSeq: 0,
    replLog: @[],
    replMetaHlc: initTable[string, Table[string, Hlc]](),
    replMetaChangeId: initTable[string, Table[string, string]]()
  )
  initLock(result.lock)
  initRwLock(result.rw)
  result.lockStripes.setLen(lockStripesCount)
  for i in 0 ..< lockStripesCount:
    initRwLock(result.lockStripes[i])
  # derive nodeId if provided
  let cfg = loadConfig()
  # Persisted/stable node id
  let nodeIdPath = dir / "node.id"
  if cfg.nodeId.len > 0:
    result.nodeId = cfg.nodeId
    # if no file exists, persist
    if not fileExists(nodeIdPath): writeFile(nodeIdPath, result.nodeId)
  elif fileExists(nodeIdPath):
    try:
      result.nodeId = readFile(nodeIdPath).strip()
    except IOError:
      result.nodeId = $nowMillis() & ":" & $cast[uint64](result)
  else:
    result.nodeId = $nowMillis() & ":" & $cast[uint64](result)
    writeFile(nodeIdPath, result.nodeId)
  # init local HLC
  result.localHlc = Hlc(wallMillis: nowMillis(), counter: 0'u32, nodeId: result.nodeId)
  # load snapshots
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".snap"):
      let name = splitFile(path).name
      result.collections[name] = loadSnapshot(dir, name)
      # Initialize versions table with 0; actual versions will be set by WAL replay
      result.versions[name] = initTable[string, uint64]()
  # peers state path
  result.peersStatePath = dir / "peers.state"
  result.peersCursors = initTable[string, uint64]()
  if fileExists(result.peersStatePath):
    try:
      let content = readFile(result.peersStatePath)
      for line in content.split('\n'):
        let ln = line.strip()
        if ln.len == 0: continue
        let parts = ln.splitWhitespace()
        if parts.len == 2:
          var n: int
          if parseInt(parts[1], n) == parts[1].len and n >= 0:
            result.peersCursors[parts[0]] = uint64(n)
    except IOError:
      discard
  # replay wal (also rebuild versions/indexes and in-memory replication log)
  for rec in replay(dir):
    var coll: CollectionStore
    if rec.collection notin result.collections:
      result.collections[rec.collection] = initTable[string, Value]()
    if rec.collection notin result.versions:
      result.versions[rec.collection] = initTable[string, uint64]()
    coll = result.collections[rec.collection]
    if rec.kind == wrPut:
      coll[rec.docId] = rec.value
      result.versions[rec.collection][rec.docId] = rec.version
      # reindex existing indexes for this collection
      if rec.collection in result.indexes:
        for _, idx in result.indexes[rec.collection]:
          idx.indexDoc(rec.docId, rec.value)
    else:
      if rec.docId in coll:
        let oldDoc = coll[rec.docId]
        if rec.collection in result.indexes:
          for _, idx in result.indexes[rec.collection]:
            idx.unindexDoc(rec.docId, oldDoc)
        coll.del(rec.docId)
      if rec.docId in result.versions[rec.collection]: result.versions[rec.collection].del(rec.docId)
    # Rebuild in-memory repl log cursor from WAL (uses v2 metadata when present)
    inc result.replSeq
    var ch: ReplChange
    ch.collection = rec.collection
    ch.docId = rec.docId
    ch.op = (if rec.kind == wrPut: roPut else: roDelete)
    ch.version = rec.version
    ch.value = rec.value
    ch.changeId = rec.changeId
    ch.originNode = rec.originNode
    ch.hlc = rec.hlc
    result.replLog.add((result.replSeq, ch))

# ---- Replication peers state and log GC ----
proc savePeersState(db: GlenDB) =
  # Snapshot peersCursors under read lock to avoid races, then write file
  acquireRead(db.rw)
  var lines: seq[string] = @[]
  for peer, seq in db.peersCursors:
    lines.add(peer & " " & $seq)
  releaseRead(db.rw)
  writeFile(db.peersStatePath, lines.join("\n"))

proc setPeerCursor*(db: GlenDB; peerId: string; seq: uint64) =
  acquireWrite(db.rw)
  db.peersCursors[peerId] = seq
  releaseWrite(db.rw)
  db.savePeersState()

proc getPeerCursor*(db: GlenDB; peerId: string): uint64 =
  acquireRead(db.rw)
  let res = (if peerId in db.peersCursors: db.peersCursors[peerId] else: 0'u64)
  releaseRead(db.rw)
  res

proc minPeerCursor(db: GlenDB): uint64 =
  var minVal: uint64 = high(uint64)
  if db.peersCursors.len == 0: return 0'u64
  for _, seq in db.peersCursors:
    if seq < minVal: minVal = seq
  minVal

proc gcReplLog*(db: GlenDB) =
  ## Trim in-memory replication log up to the minimum acknowledged cursor across peers.
  acquireWrite(db.rw)
  # Compute cutoff under the replication write lock to avoid races
  var cutoff: uint64 = high(uint64)
  if db.peersCursors.len == 0:
    cutoff = 0'u64
  else:
    for _, seq in db.peersCursors:
      if seq < cutoff: cutoff = seq
  if cutoff == 0'u64:
    releaseWrite(db.rw)
    return
  var kept: seq[(uint64, ReplChange)] = @[]
  for (seqNo, ch) in db.replLog:
    if seqNo > cutoff: kept.add((seqNo, ch))
  db.replLog = kept
  releaseWrite(db.rw)

# ---- Stripe locking helpers ----
proc stripeIndex(db: GlenDB; collection: string): int =
  if db.lockStripes.len == 0: return 0
  abs(hash(collection).int) mod db.lockStripes.len

proc acquireStripeRead(db: GlenDB; collection: string) =
  acquireRead(db.lockStripes[db.stripeIndex(collection)])

proc releaseStripeRead(db: GlenDB; collection: string) =
  releaseRead(db.lockStripes[db.stripeIndex(collection)])

proc acquireStripeWrite(db: GlenDB; collection: string) =
  acquireWrite(db.lockStripes[db.stripeIndex(collection)])

proc releaseStripeWrite(db: GlenDB; collection: string) =
  releaseWrite(db.lockStripes[db.stripeIndex(collection)])

proc acquireAllStripesWrite(db: GlenDB) =
  for i in 0 ..< db.lockStripes.len:
    acquireWrite(db.lockStripes[i])

proc releaseAllStripesWrite(db: GlenDB) =
  var i = db.lockStripes.len - 1
  while i >= 0:
    releaseWrite(db.lockStripes[i])
    if i == 0: break
    dec i

proc acquireStripesWrite(db: GlenDB; stripes: seq[int]) =
  var uniq = stripes
  uniq.sort(system.cmp[int])
  var idx = 0
  while idx < uniq.len:
    let i = uniq[idx]
    acquireWrite(db.lockStripes[i])
    inc idx
    while idx < uniq.len and uniq[idx] == i:
      inc idx

proc releaseStripesWrite(db: GlenDB; stripes: seq[int]) =
  var uniq = stripes
  uniq.sort(system.cmp[int])
  if uniq.len == 0: return
  var idx = uniq.len - 1
  while true:
    let i = uniq[idx]
    # skip duplicates while moving backward
    var j = idx
    while j > 0 and uniq[j-1] == i:
      dec j
    releaseWrite(db.lockStripes[i])
    if j == 0: break
    idx = j - 1

# ---- HLC helpers ----
proc nextLocalHlc(db: GlenDB): Hlc =
  let now = nowMillis()
  if now > db.localHlc.wallMillis:
    db.localHlc.wallMillis = now
    db.localHlc.counter = 0'u32
  else:
    db.localHlc.counter = db.localHlc.counter + 1
  db.localHlc

proc mergeRemoteHlc(db: GlenDB; remote: Hlc) =
  # Advance local clock on receipt to maintain monotonicity
  if remote.wallMillis > db.localHlc.wallMillis:
    db.localHlc.wallMillis = remote.wallMillis
    db.localHlc.counter = remote.counter
  elif remote.wallMillis == db.localHlc.wallMillis and remote.counter > db.localHlc.counter:
    db.localHlc.counter = remote.counter

## Get the current value of a document by collection and id.
## Returns nil if not found. Cached reads are served from the LRU cache.
proc get*(db: GlenDB; collection, docId: string): Value =
  let key = collection & ":" & docId
  let cached = db.cache.get(key)
  if cached != nil:
    return cached.clone()
  db.acquireStripeRead(collection)
  if collection in db.collections and docId in db.collections[collection]:
    let v = db.collections[collection][docId]
    db.cache.put(key, v)
    let cloned = v.clone()
    db.releaseStripeRead(collection)
    return cloned
  db.releaseStripeRead(collection)

# Borrowed (non-cloned) read. Caller must not mutate returned Value.
proc getBorrowed*(db: GlenDB; collection, docId: string): Value =
  let key = collection & ":" & docId
  let cached = db.cache.get(key)
  if cached != nil:
    return cached
  db.acquireStripeRead(collection)
  if collection in db.collections and docId in db.collections[collection]:
    let v = db.collections[collection][docId]
    db.cache.put(key, v)
    db.releaseStripeRead(collection)
    return v
  db.releaseStripeRead(collection)

# Transaction-aware read: records version for OCC
## Transaction-aware get. Records the version read into the provided transaction
## for optimistic concurrency control.
proc get*(db: GlenDB; collection, docId: string; t: Txn): Value =
  let v = db.get(collection, docId)
  if v != nil:
    var ver: uint64 = 0
    if collection in db.versions and docId in db.versions[collection]:
      ver = db.versions[collection][docId]
    t.recordRead(Id(collection: collection, docId: docId, version: ver))
  return v

## Batch get by ids. Returns pairs of (docId, Value) for those found.
## Uses the cache when available and acquires the DB read lock once per call.
proc getMany*(db: GlenDB; collection: string; docIds: openArray[string]): seq[(string, Value)] =
  result = @[]
  # First consult cache for fast hits
  var missing: seq[string] = @[]
  for id in docIds:
    let key = collection & ":" & id
    let cached = db.cache.get(key)
    if cached != nil:
      result.add((id, cached.clone()))
    else:
      missing.add(id)
  if missing.len == 0: return
  # Fill misses under a single read lock
  db.acquireStripeRead(collection)
  if collection in db.collections:
    let coll = db.collections[collection]
    for id in missing:
      if id in coll:
        let v = coll[id]
        db.cache.put(collection & ":" & id, v)
        result.add((id, v.clone()))
  db.releaseStripeRead(collection)

## Borrowed batch get: returns refs without cloning. Caller must not mutate.
proc getBorrowedMany*(db: GlenDB; collection: string; docIds: openArray[string]): seq[(string, Value)] =
  result = @[]
  var missing: seq[string] = @[]
  for id in docIds:
    let key = collection & ":" & id
    let cached = db.cache.get(key)
    if cached != nil:
      result.add((id, cached))
    else:
      missing.add(id)
  if missing.len == 0: return
  db.acquireStripeRead(collection)
  if collection in db.collections:
    let coll = db.collections[collection]
    for id in missing:
      if id in coll:
        let v = coll[id]
        db.cache.put(collection & ":" & id, v)
        result.add((id, v))
  db.releaseStripeRead(collection)

## Transaction-aware batch get. Records read versions for OCC.
proc getMany*(db: GlenDB; collection: string; docIds: openArray[string]; t: Txn): seq[(string, Value)] =
  let pairs = db.getMany(collection, docIds)
  for (id, _) in pairs:
    var ver: uint64 = 0
    if collection in db.versions and id in db.versions[collection]:
      ver = db.versions[collection][id]
    t.recordRead(Id(collection: collection, docId: id, version: ver))
  return pairs

## Get all documents in a collection. Returns pairs of (docId, Value).
proc getAll*(db: GlenDB; collection: string): seq[(string, Value)] =
  result = @[]
  db.acquireStripeRead(collection)
  if collection in db.collections:
    for id, v in db.collections[collection]:
      db.cache.put(collection & ":" & id, v)
      result.add((id, v.clone()))
  db.releaseStripeRead(collection)

## Borrowed getAll: returns refs without cloning. Caller must not mutate.
proc getBorrowedAll*(db: GlenDB; collection: string): seq[(string, Value)] =
  result = @[]
  db.acquireStripeRead(collection)
  if collection in db.collections:
    for id, v in db.collections[collection]:
      db.cache.put(collection & ":" & id, v)
      result.add((id, v))
  db.releaseStripeRead(collection)

## Transaction-aware getAll. Records read versions for all returned docs.
proc getAll*(db: GlenDB; collection: string; t: Txn): seq[(string, Value)] =
  let pairs = db.getAll(collection)
  for (id, _) in pairs:
    var ver: uint64 = 0
    if collection in db.versions and id in db.versions[collection]:
      ver = db.versions[collection][id]
    t.recordRead(Id(collection: collection, docId: id, version: ver))
  return pairs

## Upsert a document value. Appends to WAL, updates in-memory state, versions,
## cache, and notifies subscribers.
proc put*(db: GlenDB; collection, docId: string; value: Value) =
  acquireWrite(db.rw)
  var notifications: seq[(Id, Value)] = @[]
  var fieldNotifications: seq[(Id, Value, Value)] = @[]
  db.acquireStripeWrite(collection)
  if collection notin db.collections:
    db.collections[collection] = initTable[string, Value]()
  if collection notin db.versions:
    db.versions[collection] = initTable[string, uint64]()
  var oldVer = 0'u64
  if docId in db.versions[collection]: oldVer = db.versions[collection][docId]
  let newVer = oldVer + 1
  var stored = value.clone()
  # assign replication metadata and append to WAL before mutating (write-ahead)
  inc db.replSeq
  let chHlc = db.nextLocalHlc()
  let chChangeId = $db.replSeq & ":" & db.nodeId
  db.wal.append(WalRecord(kind: wrPut, collection: collection, docId: docId, version: newVer, value: stored, changeId: chChangeId, originNode: db.nodeId, hlc: chHlc))
  # record replication change (local origin)
  let ch = ReplChange(collection: collection, docId: docId, op: roPut, version: newVer, value: stored, changeId: chChangeId, originNode: db.nodeId, hlc: chHlc)
  db.replLog.add((db.replSeq, ch))
  # update local replication metadata for conflict resolution/idempotency
  if collection notin db.replMetaHlc: db.replMetaHlc[collection] = initTable[string, Hlc]()
  if collection notin db.replMetaChangeId: db.replMetaChangeId[collection] = initTable[string, string]()
  db.replMetaHlc[collection][docId] = chHlc
  db.replMetaChangeId[collection][docId] = chChangeId
  var oldDoc: Value = nil
  if docId in db.collections[collection]: oldDoc = db.collections[collection][docId]
  db.collections[collection][docId] = stored
  db.versions[collection][docId] = newVer
  db.cache.put(collection & ":" & docId, stored)
  if collection in db.indexes:
    for _, idx in db.indexes[collection]:
      idx.reindexDoc(docId, oldDoc, stored)
  notifications.add((Id(collection: collection, docId: docId, version: newVer), stored))
  fieldNotifications.add((Id(collection: collection, docId: docId, version: newVer), oldDoc, stored))
  db.releaseStripeWrite(collection)
  releaseWrite(db.rw)
  for it in notifications:
    db.subs.notify(it[0], it[1])
  for it in fieldNotifications:
    db.subs.notifyFieldChanges(it[0], it[1], it[2])

## Delete a document if it exists. Appends a delete to WAL, removes from
## in-memory state and cache, bumps the version, and notifies subscribers.
proc delete*(db: GlenDB; collection, docId: string) =
  acquireWrite(db.rw)
  var notifications: seq[(Id, Value)] = @[]
  var fieldNotifications: seq[(Id, Value, Value)] = @[]
  db.acquireStripeWrite(collection)
  if collection in db.collections and docId in db.collections[collection]:
    var ver = 1'u64
    if collection in db.versions and docId in db.versions[collection]:
      ver = db.versions[collection][docId] + 1
    inc db.replSeq
    let chHlc = db.nextLocalHlc()
    let chChangeId = $db.replSeq & ":" & db.nodeId
    db.wal.append(WalRecord(kind: wrDelete, collection: collection, docId: docId, version: ver, changeId: chChangeId, originNode: db.nodeId, hlc: chHlc))
    let ch = ReplChange(collection: collection, docId: docId, op: roDelete, version: ver, value: nil, changeId: chChangeId, originNode: db.nodeId, hlc: chHlc)
    db.replLog.add((db.replSeq, ch))
    if collection notin db.replMetaHlc: db.replMetaHlc[collection] = initTable[string, Hlc]()
    if collection notin db.replMetaChangeId: db.replMetaChangeId[collection] = initTable[string, string]()
    db.replMetaHlc[collection][docId] = chHlc
    db.replMetaChangeId[collection][docId] = chChangeId
    var oldDoc = db.collections[collection][docId]
    if collection in db.indexes:
      for _, idx in db.indexes[collection]:
        idx.unindexDoc(docId, oldDoc)
    db.collections[collection].del(docId)
    if collection in db.versions and docId in db.versions[collection]: db.versions[collection].del(docId)
    # Invalidate cache
    db.cache.del(collection & ":" & docId)
    notifications.add((Id(collection: collection, docId: docId, version: ver), VNull()))
    fieldNotifications.add((Id(collection: collection, docId: docId, version: ver), oldDoc, nil))
  db.releaseStripeWrite(collection)
  releaseWrite(db.rw)
  for it in notifications:
    db.subs.notify(it[0], it[1])
  for it in fieldNotifications:
    db.subs.notifyFieldChanges(it[0], it[1], it[2])

# Transaction support
## Begin a new transaction (optimistic).
proc beginTxn*(db: GlenDB): Txn = newTxn()

# Internal helper to fetch current version for OCC
## Return the current version for a (collection, docId), or 0 if not present.
proc currentVersion*(db: GlenDB; collection, docId: string): uint64 =
  if collection in db.versions and docId in db.versions[collection]:
    return db.versions[collection][docId]
  return 0

## Attempt to commit the provided transaction using optimistic concurrency.
## Validates recorded read versions against current versions and applies staged
## writes on success. Returns a CommitResult with status and message.
proc commit*(db: GlenDB; t: Txn): CommitResult =
  var notifications: seq[(Id, Value)] = @[]
  var fieldNotifications: seq[(Id, Value, Value)] = @[]
  # Acquire global replication write lock first to serialize access to replSeq/localHlc/replLog
  acquireWrite(db.rw)
  # Acquire all needed collection stripes in sorted order
  var stripes: seq[int] = @[]
  for key, _ in t.writes:
    stripes.add(db.stripeIndex(key[0]))
  db.acquireStripesWrite(stripes)
  if t.state != tsActive:
    db.releaseStripesWrite(stripes)
    return CommitResult(status: csInvalid, message: "Transaction not active")
  # validate
  for k, ver in t.readVersions:
    let parts = k.split(":")
    if parts.len != 2: continue
    let cur = db.currentVersion(parts[0], parts[1])
    if cur != ver:
      t.state = tsRolledBack
      db.releaseStripesWrite(stripes)
      releaseWrite(db.rw)
      return CommitResult(status: csConflict, message: "Version mismatch for " & k)
  # apply writes (compute WAL with replication metadata, then mutate, then log)
  var walRecs: seq[WalRecord] = @[]
  var replEntries: seq[(uint64, ReplChange)] = @[]
  for key, w in t.writes:
    let collection = key[0]
    let docId = key[1]
    if w.kind == twDelete:
      if collection in db.collections and docId in db.collections[collection]:
        let newVer = db.currentVersion(collection, docId) + 1
        inc db.replSeq
        let chHlc = db.nextLocalHlc()
        let chChangeId = $db.replSeq & ":" & db.nodeId
        walRecs.add(WalRecord(kind: wrDelete, collection: collection, docId: docId, version: newVer, changeId: chChangeId, originNode: db.nodeId, hlc: chHlc))
        var oldDoc = db.collections[collection][docId]
        if collection in db.indexes:
          for _, idx in db.indexes[collection]:
            idx.unindexDoc(docId, oldDoc)
        db.collections[collection].del(docId)
        if collection in db.versions and docId in db.versions[collection]:
          db.versions[collection].del(docId)
        db.cache.del(collection & ":" & docId)
        notifications.add((Id(collection: collection, docId: docId, version: newVer), VNull()))
        fieldNotifications.add((Id(collection: collection, docId: docId, version: newVer), oldDoc, nil))
        let ch = ReplChange(collection: collection, docId: docId, op: roDelete, version: newVer, value: nil, changeId: chChangeId, originNode: db.nodeId, hlc: chHlc)
        replEntries.add((db.replSeq, ch))
        if collection notin db.replMetaHlc: db.replMetaHlc[collection] = initTable[string, Hlc]()
        if collection notin db.replMetaChangeId: db.replMetaChangeId[collection] = initTable[string, string]()
        db.replMetaHlc[collection][docId] = chHlc
        db.replMetaChangeId[collection][docId] = chChangeId
    else:
      if collection notin db.collections:
        db.collections[collection] = initTable[string, Value]()
      let newVer = db.currentVersion(collection, docId) + 1
      inc db.replSeq
      let chHlc = db.nextLocalHlc()
      let chChangeId = $db.replSeq & ":" & db.nodeId
      walRecs.add(WalRecord(kind: wrPut, collection: collection, docId: docId, version: newVer, value: w.value, changeId: chChangeId, originNode: db.nodeId, hlc: chHlc))
      var oldDoc: Value = nil
      if collection in db.collections and docId in db.collections[collection]:
        oldDoc = db.collections[collection][docId]
      db.collections[collection][docId] = w.value
      if collection notin db.versions:
        db.versions[collection] = initTable[string, uint64]()
      db.versions[collection][docId] = newVer
      db.cache.put(collection & ":" & docId, w.value)
      if collection in db.indexes:
        for _, idx in db.indexes[collection]:
          idx.reindexDoc(docId, oldDoc, w.value)
      notifications.add((Id(collection: collection, docId: docId, version: newVer), w.value))
      fieldNotifications.add((Id(collection: collection, docId: docId, version: newVer), oldDoc, w.value))
      let ch = ReplChange(collection: collection, docId: docId, op: roPut, version: newVer, value: w.value, changeId: chChangeId, originNode: db.nodeId, hlc: chHlc)
      replEntries.add((db.replSeq, ch))
      if collection notin db.replMetaHlc: db.replMetaHlc[collection] = initTable[string, Hlc]()
      if collection notin db.replMetaChangeId: db.replMetaChangeId[collection] = initTable[string, string]()
      db.replMetaHlc[collection][docId] = chHlc
      db.replMetaChangeId[collection][docId] = chChangeId
  if walRecs.len > 0:
    db.wal.appendMany(walRecs)
  # record replication changes (with precomputed seq)
  for entry in replEntries:
    db.replLog.add(entry)
  t.state = tsCommitted
  db.releaseStripesWrite(stripes)
  releaseWrite(db.rw)
  for it in notifications:
    db.subs.notify(it[0], it[1])
  for it in fieldNotifications:
    db.subs.notifyFieldChanges(it[0], it[1], it[2])
  return CommitResult(status: csOk)

## Subscribe to updates for a specific (collection, docId). Returns a handle
## that can be passed to unsubscribe.
proc subscribe*(db: GlenDB; collection, docId: string; cb: SubscriberCallback): SubscriptionHandle =
  result = db.subs.subscribe(collection, docId, cb)

## Remove a previously registered subscription using its handle.
proc unsubscribe*(db: GlenDB; h: SubscriptionHandle) =
  db.subs.unsubscribe(h)

## Subscribe and stream updates as framed events into the provided Stream.
proc subscribeStream*(db: GlenDB; collection, docId: string; s: Stream): SubscriptionHandle =
  result = db.subs.subscribeStream(collection, docId, s)

## Field-level subscriptions
proc subscribeField*(db: GlenDB; collection, docId: string; fieldPath: string; cb: FieldCallback): FieldSubscriptionHandle =
  result = db.subs.subscribeField(collection, docId, fieldPath, cb)

proc unsubscribeField*(db: GlenDB; h: FieldSubscriptionHandle) =
  db.subs.unsubscribeField(h)

proc subscribeFieldStream*(db: GlenDB; collection, docId: string; fieldPath: string; s: Stream): FieldSubscriptionHandle =
  result = db.subs.subscribeFieldStream(collection, docId, fieldPath, s)

proc subscribeFieldDelta*(db: GlenDB; collection, docId: string; fieldPath: string; cb: FieldDeltaCallback): FieldDeltaSubscriptionHandle =
  result = db.subs.subscribeFieldDelta(collection, docId, fieldPath, cb)

proc unsubscribeFieldDelta*(db: GlenDB; h: FieldDeltaSubscriptionHandle) =
  db.subs.unsubscribeFieldDelta(h)

proc subscribeFieldDeltaStream*(db: GlenDB; collection, docId: string; fieldPath: string; s: Stream): FieldDeltaSubscriptionHandle =
  result = db.subs.subscribeFieldDeltaStream(collection, docId, fieldPath, s)

## Batch put: apply multiple upserts under one write lock, batch WAL appends, update indexes and cache.
proc putMany*(db: GlenDB; collection: string; items: openArray[(string, Value)]) =
  acquireWrite(db.rw)
  var notifications: seq[(Id, Value)] = @[]
  var fieldNotifications: seq[(Id, Value, Value)] = @[]
  db.acquireStripeWrite(collection)
  if collection notin db.collections:
    db.collections[collection] = initTable[string, Value]()
  if collection notin db.versions:
    db.versions[collection] = initTable[string, uint64]()
  var walRecs: seq[WalRecord] = @[]
  var replEntries: seq[(uint64, ReplChange)] = @[]
  for (docId, value) in items:
    var oldVer = 0'u64
    if docId in db.versions[collection]: oldVer = db.versions[collection][docId]
    let newVer = oldVer + 1
    var stored = value.clone()
    inc db.replSeq
    let chHlc = db.nextLocalHlc()
    let chChangeId = $db.replSeq & ":" & db.nodeId
    walRecs.add(WalRecord(kind: wrPut, collection: collection, docId: docId, version: newVer, value: stored, changeId: chChangeId, originNode: db.nodeId, hlc: chHlc))
    replEntries.add((db.replSeq, ReplChange(collection: collection, docId: docId, op: roPut, version: newVer, value: stored, changeId: chChangeId, originNode: db.nodeId, hlc: chHlc)))
    if collection notin db.replMetaHlc: db.replMetaHlc[collection] = initTable[string, Hlc]()
    if collection notin db.replMetaChangeId: db.replMetaChangeId[collection] = initTable[string, string]()
    db.replMetaHlc[collection][docId] = chHlc
    db.replMetaChangeId[collection][docId] = chChangeId
    var oldDoc: Value = nil
    if docId in db.collections[collection]: oldDoc = db.collections[collection][docId]
    db.collections[collection][docId] = stored
    db.versions[collection][docId] = newVer
    db.cache.put(collection & ":" & docId, stored)
    if collection in db.indexes:
      for _, idx in db.indexes[collection]:
        idx.reindexDoc(docId, oldDoc, stored)
    notifications.add((Id(collection: collection, docId: docId, version: newVer), stored))
    fieldNotifications.add((Id(collection: collection, docId: docId, version: newVer), oldDoc, stored))
  if walRecs.len > 0: db.wal.appendMany(walRecs)
  # replication log for batch
  for entry in replEntries:
    db.replLog.add(entry)
  db.releaseStripeWrite(collection)
  releaseWrite(db.rw)
  for it in notifications: db.subs.notify(it[0], it[1])
  for it in fieldNotifications: db.subs.notifyFieldChanges(it[0], it[1], it[2])

## Batch delete: delete multiple documents under one write lock, batch WAL appends.
proc deleteMany*(db: GlenDB; collection: string; docIds: openArray[string]) =
  acquireWrite(db.rw)
  var notifications: seq[(Id, Value)] = @[]
  var fieldNotifications: seq[(Id, Value, Value)] = @[]
  db.acquireStripeWrite(collection)
  if collection notin db.collections:
    db.releaseStripeWrite(collection)
    releaseWrite(db.rw)
    return
  var walRecs: seq[WalRecord] = @[]
  var replEntries: seq[(uint64, ReplChange)] = @[]
  for docId in docIds:
    if docId in db.collections[collection]:
      var ver = 1'u64
      if collection in db.versions and docId in db.versions[collection]:
        ver = db.versions[collection][docId] + 1
      inc db.replSeq
      let chHlc = db.nextLocalHlc()
      let chChangeId = $db.replSeq & ":" & db.nodeId
      walRecs.add(WalRecord(kind: wrDelete, collection: collection, docId: docId, version: ver, changeId: chChangeId, originNode: db.nodeId, hlc: chHlc))
      replEntries.add((db.replSeq, ReplChange(collection: collection, docId: docId, op: roDelete, version: ver, value: nil, changeId: chChangeId, originNode: db.nodeId, hlc: chHlc)))
      if collection notin db.replMetaHlc: db.replMetaHlc[collection] = initTable[string, Hlc]()
      if collection notin db.replMetaChangeId: db.replMetaChangeId[collection] = initTable[string, string]()
      db.replMetaHlc[collection][docId] = chHlc
      db.replMetaChangeId[collection][docId] = chChangeId
      var oldDoc = db.collections[collection][docId]
      if collection in db.indexes:
        for _, idx in db.indexes[collection]:
          idx.unindexDoc(docId, oldDoc)
      db.collections[collection].del(docId)
      if collection in db.versions and docId in db.versions[collection]: db.versions[collection].del(docId)
      db.cache.del(collection & ":" & docId)
      notifications.add((Id(collection: collection, docId: docId, version: ver), VNull()))
      fieldNotifications.add((Id(collection: collection, docId: docId, version: ver), oldDoc, nil))
  if walRecs.len > 0: db.wal.appendMany(walRecs)
  for entry in replEntries:
    db.replLog.add(entry)
  db.releaseStripeWrite(collection)
  releaseWrite(db.rw)
  for it in notifications: db.subs.notify(it[0], it[1])
  for it in fieldNotifications: db.subs.notifyFieldChanges(it[0], it[1], it[2])

# Snapshot trigger (simple: write all collections)
## Write snapshots for all collections to durable storage.
proc snapshotAll*(db: GlenDB) =
  db.acquireAllStripesWrite()
  defer: db.releaseAllStripesWrite()
  for collection, docs in db.collections:
    writeSnapshot(db.dir, collection, docs)

## Create an equality index on a field path (e.g., "name" or "profile.age").
proc createIndex*(db: GlenDB; collection: string; name: string; fieldPath: string) =
  db.acquireStripeWrite(collection)
  defer: db.releaseStripeWrite(collection)
  if collection notin db.indexes:
    db.indexes[collection] = initTable[string, Index]()
  let idx = newIndex(name, fieldPath)
  # build from existing docs
  if collection in db.collections:
    for id, v in db.collections[collection]:
      idx.indexDoc(id, v)
  db.indexes[collection][name] = idx

## Drop an existing index by name.
proc dropIndex*(db: GlenDB; collection: string; name: string) =
  db.acquireStripeWrite(collection)
  defer: db.releaseStripeWrite(collection)
  if collection in db.indexes and name in db.indexes[collection]:
    db.indexes[collection].del(name)

## Query documents by equality on an indexed field. Optional limit.
proc findBy*(db: GlenDB; collection: string; indexName: string; keyValue: Value; limit = 0): seq[(string, Value)] =
  db.acquireStripeRead(collection)
  defer: db.releaseStripeRead(collection)
  if collection notin db.indexes or indexName notin db.indexes[collection]: return @[]
  let idx = db.indexes[collection][indexName]
  result = @[]
  for id in idx.findEq(keyValue, limit):
    if collection in db.collections and id in db.collections[collection]:
      result.add((id, db.collections[collection][id]))

## Range query on a single-field index, with order and limit.
proc rangeBy*(db: GlenDB; collection: string; indexName: string; minVal, maxVal: Value; inclusiveMin = true; inclusiveMax = true; limit = 0; asc = true): seq[(string, Value)] =
  db.acquireStripeRead(collection)
  defer: db.releaseStripeRead(collection)
  if collection notin db.indexes or indexName notin db.indexes[collection]: return @[]
  let idx = db.indexes[collection][indexName]
  result = @[]
  for id in idx.findRange(minVal, maxVal, inclusiveMin, inclusiveMax, limit, asc):
    if collection in db.collections and id in db.collections[collection]:
      result.add((id, db.collections[collection][id]))

# Compaction: snapshot all collections and truncate WAL
## Snapshot all collections and truncate the WAL so that recovery can start
## from the snapshots and a fresh log.
proc compact*(db: GlenDB) =
  db.acquireAllStripesWrite()
  defer: db.releaseAllStripesWrite()
  for collection, docs in db.collections:
    writeSnapshot(db.dir, collection, docs)
  # Reset WAL after snapshot to start a new, empty log
  if db.wal != nil:
    db.wal.reset()

# Close database resources
## Close database resources (WAL file handles).
proc close*(db: GlenDB) =
  db.acquireAllStripesWrite()
  defer: db.releaseAllStripesWrite()
  if db.wal != nil:
    db.wal.close()

proc cacheStats*(db: GlenDB): CacheStats =
  db.cache.stats()

proc setWalSync*(db: GlenDB; mode: WalSyncMode; flushEveryBytes = 0) =
  db.acquireAllStripesWrite()
  defer: db.releaseAllStripesWrite()
  if db.wal != nil:
    db.wal.setSyncPolicy(mode, flushEveryBytes)

proc newGlenDBFromEnv*(dir: string): GlenDB =
  let cfg = loadConfig()
  var mode = wsmInterval
  if cfg.walSyncMode == "always": mode = wsmAlways
  elif cfg.walSyncMode == "none": mode = wsmNone
  result = newGlenDB(
    dir,
    cacheCapacity = cfg.cacheCapacityBytes,
    cacheShards = cfg.cacheShards,
    walSync = mode,
    walFlushEveryBytes = cfg.walFlushEveryBytes
  )

# -------- Replication (multi-master) API --------

type ReplExportCursor* = uint64

proc exportChanges*(db: GlenDB; since: ReplExportCursor; includeCollections: seq[string] = @[]; excludeCollections: seq[string] = @[]): (ReplExportCursor, seq[ReplChange]) =
  ## Export changes after the provided cursor, filtered by collection allow/deny lists.
  ## Returns the new cursor and a sequence of changes.
  var allow = initTable[string, bool]()
  if includeCollections.len > 0:
    for c in includeCollections: allow[c] = true
  var deny = initTable[string, bool]()
  for c in excludeCollections: deny[c] = true
  var changesOut: seq[ReplChange] = @[]
  var nextCursor = since
  acquireRead(db.rw)
  for (seqNo, ch) in db.replLog:
    if seqNo <= since: continue
    if includeCollections.len > 0 and ch.collection notin allow: continue
    if ch.collection in deny: continue
    # ensure we only export entries that have metadata (after WAL v2 or local ops)
    if ch.changeId.len == 0: continue
    changesOut.add(ch)
    if seqNo > nextCursor: nextCursor = seqNo
  let res = (nextCursor, changesOut)
  releaseRead(db.rw)
  return res

proc applyChanges*(db: GlenDB; changes: openArray[ReplChange]) =
  ## Apply a batch of changes from a remote node. Idempotent via changeId; resolves conflicts using HLC (LWW semantics).
  var notifications: seq[(Id, Value)] = @[]
  var fieldNotifications: seq[(Id, Value, Value)] = @[]
  var acceptedAny = false
  # Serialize with local writers and export by taking the replication write lock
  acquireWrite(db.rw)
  # Acquire all required collection stripe locks to make this batch atomic
  var stripes: seq[int] = @[]
  for ch in changes:
    stripes.add(db.stripeIndex(ch.collection))
  db.acquireStripesWrite(stripes)
  for ch in changes:
    let coll = ch.collection
    let id = ch.docId
    # init per-collection maps
    if coll notin db.collections: db.collections[coll] = initTable[string, Value]()
    if coll notin db.versions: db.versions[coll] = initTable[string, uint64]()
    if coll notin db.replMetaHlc: db.replMetaHlc[coll] = initTable[string, Hlc]()
    if coll notin db.replMetaChangeId: db.replMetaChangeId[coll] = initTable[string, string]()
    # idempotency
    if id in db.replMetaChangeId[coll] and db.replMetaChangeId[coll][id] == ch.changeId:
      db.mergeRemoteHlc(ch.hlc)
      continue
    # conflict resolution (LWW by HLC)
    var accept = true
    if id in db.replMetaHlc[coll]:
      let cur = db.replMetaHlc[coll][id]
      if hlcCompare(ch.hlc, cur) < 0:
        accept = false
    if accept:
      acceptedAny = true
      if ch.op == roDelete:
        var oldDoc: Value = nil
        if id in db.collections[coll]:
          oldDoc = db.collections[coll][id]
          if coll in db.indexes:
            for _, idx in db.indexes[coll]: idx.unindexDoc(id, oldDoc)
          # WAL append for remote delete BEFORE mutating state
          db.wal.append(WalRecord(kind: wrDelete, collection: coll, docId: id, version: ch.version, changeId: ch.changeId, originNode: ch.originNode, hlc: ch.hlc))
          db.collections[coll].del(id)
        if id in db.versions[coll]: db.versions[coll].del(id)
        db.cache.del(coll & ":" & id)
        notifications.add((Id(collection: coll, docId: id, version: ch.version), VNull()))
        fieldNotifications.add((Id(collection: coll, docId: id, version: ch.version), oldDoc, nil))
      else:
        var stored = if ch.value.isNil: VNull() else: ch.value
        var oldDoc: Value = nil
        if id in db.collections[coll]: oldDoc = db.collections[coll][id]
        # WAL append for remote put BEFORE mutating state
        db.wal.append(WalRecord(kind: wrPut, collection: coll, docId: id, version: ch.version, value: stored, changeId: ch.changeId, originNode: ch.originNode, hlc: ch.hlc))
        db.collections[coll][id] = stored
        db.versions[coll][id] = ch.version
        db.cache.put(coll & ":" & id, stored)
        if coll in db.indexes:
          for _, idx in db.indexes[coll]: idx.reindexDoc(id, oldDoc, stored)
        notifications.add((Id(collection: coll, docId: id, version: ch.version), stored))
        fieldNotifications.add((Id(collection: coll, docId: id, version: ch.version), oldDoc, stored))
      db.replMetaHlc[coll][id] = ch.hlc
      db.replMetaChangeId[coll][id] = ch.changeId
    # Merge remote HLC into local clock under lock
    db.mergeRemoteHlc(ch.hlc)
  db.releaseStripesWrite(stripes)
  releaseWrite(db.rw)
  # Fire notifications outside locks
  for it in notifications:
    db.subs.notify(it[0], it[1])
  for it in fieldNotifications:
    db.subs.notifyFieldChanges(it[0], it[1], it[2])
  if acceptedAny and db.wal != nil:
    db.wal.flush()

