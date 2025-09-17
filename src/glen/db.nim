# Glen DB high-level API

import std/[os, tables, locks, strutils]
import glen/types, glen/wal, glen/storage, glen/cache, glen/subscription, glen/txn
import glen/index
import glen/errors

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

## Create or open a Glen database at the given directory.
## Loads snapshots, replays the WAL, and initializes cache and subscriptions.
proc newGlenDB*(dir: string; cacheCapacity = 4*1024*1024): GlenDB =
  result = GlenDB(
    dir: dir,
    wal: openWriteAheadLog(dir),
    collections: initTable[string, CollectionStore](),
    versions: initTable[string, Table[string, uint64]](),
    cache: newLruCache(cacheCapacity),
    subs: newSubscriptionManager(),
    indexes: initTable[string, IndexesByName]()
  )
  initLock(result.lock)
  # load snapshots
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".snap"):
      let name = splitFile(path).name
      result.collections[name] = loadSnapshot(dir, name)
      # Initialize versions table with 0; actual versions will be set by WAL replay
      result.versions[name] = initTable[string, uint64]()
  # replay wal
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
      if rec.docId in coll: coll.del(rec.docId)
      if rec.docId in result.versions[rec.collection]: result.versions[rec.collection].del(rec.docId)
      if rec.collection in result.indexes:
        for _, idx in result.indexes[rec.collection]:
          idx.unindexDoc(rec.docId, rec.value)

## Get the current value of a document by collection and id.
## Returns nil if not found. Cached reads are served from the LRU cache.
proc get*(db: GlenDB; collection, docId: string): Value =
  let key = collection & ":" & docId
  let cached = db.cache.get(key)
  if cached != nil: return cached
  acquire(db.lock)
  defer: release(db.lock)
  if collection in db.collections and docId in db.collections[collection]:
    let v = db.collections[collection][docId]
    db.cache.put(key, v)
    return v

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

## Upsert a document value. Appends to WAL, updates in-memory state, versions,
## cache, and notifies subscribers.
proc put*(db: GlenDB; collection, docId: string; value: Value) =
  acquire(db.lock)
  defer: release(db.lock)
  if collection notin db.collections:
    db.collections[collection] = initTable[string, Value]()
  if collection notin db.versions:
    db.versions[collection] = initTable[string, uint64]()
  var oldVer = 0'u64
  if docId in db.versions[collection]: oldVer = db.versions[collection][docId]
  let newVer = oldVer + 1
  # Wrap value inside object with _id field for versioning convenience (optional design)
  var stored = value.clone()
  # Append wal
  db.wal.append(WalRecord(kind: wrPut, collection: collection, docId: docId, version: newVer, value: stored))
  db.collections[collection][docId] = stored
  db.versions[collection][docId] = newVer
  db.cache.put(collection & ":" & docId, stored)
  # index update
  if collection in db.indexes:
    for _, idx in db.indexes[collection]:
      idx.indexDoc(docId, stored)
  db.subs.notify(Id(collection: collection, docId: docId, version: newVer), stored)

## Delete a document if it exists. Appends a delete to WAL, removes from
## in-memory state and cache, bumps the version, and notifies subscribers.
proc delete*(db: GlenDB; collection, docId: string) =
  acquire(db.lock)
  defer: release(db.lock)
  if collection in db.collections and docId in db.collections[collection]:
    var ver = 1'u64
    if collection in db.versions and docId in db.versions[collection]:
      ver = db.versions[collection][docId] + 1
    db.wal.append(WalRecord(kind: wrDelete, collection: collection, docId: docId, version: ver))
    var oldDoc = db.collections[collection][docId]
    db.collections[collection].del(docId)
    if collection in db.versions and docId in db.versions[collection]: db.versions[collection].del(docId)
    # Invalidate cache
    db.cache.del(collection & ":" & docId)
    # index update
    if collection in db.indexes:
      for _, idx in db.indexes[collection]:
        idx.unindexDoc(docId, oldDoc)
    # Notify deletion with null
    db.subs.notify(Id(collection: collection, docId: docId, version: ver), VNull())

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
  acquire(db.lock)
  defer: release(db.lock)
  if t.state != tsActive:
    return CommitResult(status: csInvalid, message: "Transaction not active")
  # validate
  for k, ver in t.readVersions:
    let parts = k.split(":")
    if parts.len != 2: continue
    let cur = db.currentVersion(parts[0], parts[1])
    if cur != ver:
      t.state = tsRolledBack
      return CommitResult(status: csConflict, message: "Version mismatch for " & k)
  # apply writes
  for k, w in t.writes:
    let parts = k.split(":")
    if parts.len != 2:
      continue
    let collection = parts[0]
    let docId = parts[1]
    if w.kind == twDelete:
      if collection in db.collections and docId in db.collections[collection]:
        let newVer = db.currentVersion(collection, docId) + 1
        db.wal.append(WalRecord(kind: wrDelete, collection: collection, docId: docId, version: newVer))
        var oldDoc = db.collections[collection][docId]
        db.collections[collection].del(docId)
        if collection in db.versions and docId in db.versions[collection]:
          db.versions[collection].del(docId)
        db.cache.del(collection & ":" & docId)
        if collection in db.indexes:
          for _, idx in db.indexes[collection]:
            idx.unindexDoc(docId, oldDoc)
        db.subs.notify(Id(collection: collection, docId: docId, version: newVer), VNull())
    else:
      if collection notin db.collections:
        db.collections[collection] = initTable[string, Value]()
      let newVer = db.currentVersion(collection, docId) + 1
      db.wal.append(WalRecord(kind: wrPut, collection: collection, docId: docId, version: newVer, value: w.value))
      db.collections[collection][docId] = w.value
      if collection notin db.versions:
        db.versions[collection] = initTable[string, uint64]()
      db.versions[collection][docId] = newVer
      # Mirror non-transactional put: update cache for the written document
      db.cache.put(collection & ":" & docId, w.value)
      if collection in db.indexes:
        for _, idx in db.indexes[collection]:
          idx.indexDoc(docId, w.value)
      db.subs.notify(Id(collection: collection, docId: docId, version: newVer), w.value)
  t.state = tsCommitted
  return CommitResult(status: csOk)

## Subscribe to updates for a specific (collection, docId). Returns a handle
## that can be passed to unsubscribe.
proc subscribe*(db: GlenDB; collection, docId: string; cb: SubscriberCallback): SubscriptionHandle =
  result = db.subs.subscribe(collection, docId, cb)

## Remove a previously registered subscription using its handle.
proc unsubscribe*(db: GlenDB; h: SubscriptionHandle) =
  db.subs.unsubscribe(h)

# Snapshot trigger (simple: write all collections)
## Write snapshots for all collections to durable storage.
proc snapshotAll*(db: GlenDB) =
  acquire(db.lock)
  defer: release(db.lock)
  for collection, docs in db.collections:
    writeSnapshot(db.dir, collection, docs)

## Create an equality index on a field path (e.g., "name" or "profile.age").
proc createIndex*(db: GlenDB; collection: string; name: string; fieldPath: string) =
  acquire(db.lock)
  defer: release(db.lock)
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
  acquire(db.lock)
  defer: release(db.lock)
  if collection in db.indexes and name in db.indexes[collection]:
    db.indexes[collection].del(name)

## Query documents by equality on an indexed field. Optional limit.
proc findBy*(db: GlenDB; collection: string; indexName: string; keyValue: Value; limit = 0): seq[(string, Value)] =
  acquire(db.lock)
  defer: release(db.lock)
  if collection notin db.indexes or indexName notin db.indexes[collection]: return @[]
  let idx = db.indexes[collection][indexName]
  result = @[]
  for id in idx.findEq(keyValue, limit):
    if collection in db.collections and id in db.collections[collection]:
      result.add((id, db.collections[collection][id]))

## Range query on a single-field index, with order and limit.
proc rangeBy*(db: GlenDB; collection: string; indexName: string; minVal, maxVal: Value; inclusiveMin = true; inclusiveMax = true; limit = 0; asc = true): seq[(string, Value)] =
  acquire(db.lock)
  defer: release(db.lock)
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
  acquire(db.lock)
  defer: release(db.lock)
  for collection, docs in db.collections:
    writeSnapshot(db.dir, collection, docs)
  # Reset WAL after snapshot to start a new, empty log
  if db.wal != nil:
    db.wal.reset()

# Close database resources
## Close database resources (WAL file handles).
proc close*(db: GlenDB) =
  acquire(db.lock)
  defer: release(db.lock)
  if db.wal != nil:
    db.wal.close()

