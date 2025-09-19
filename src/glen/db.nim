# Glen DB high-level API

import std/[os, tables, locks, strutils, streams]
import glen/types, glen/wal, glen/storage, glen/cache, glen/subscription, glen/txn
import glen/rwlock
import glen/index

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

## Create or open a Glen database at the given directory.
## Loads snapshots, replays the WAL, and initializes cache and subscriptions.
proc newGlenDB*(dir: string; cacheCapacity = 64*1024*1024; cacheShards = 16; walSync: WalSyncMode = wsmInterval; walFlushEveryBytes = 8*1024*1024): GlenDB =
  result = GlenDB(
    dir: dir,
    wal: openWriteAheadLog(dir, syncMode = walSync, flushEveryBytes = walFlushEveryBytes),
    collections: initTable[string, CollectionStore](),
    versions: initTable[string, Table[string, uint64]](),
    cache: newLruCache(cacheCapacity, numShards = cacheShards),
    subs: newSubscriptionManager(),
    indexes: initTable[string, IndexesByName]()
  )
  initLock(result.lock)
  initRwLock(result.rw)
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
      if rec.docId in coll:
        let oldDoc = coll[rec.docId]
        if rec.collection in result.indexes:
          for _, idx in result.indexes[rec.collection]:
            idx.unindexDoc(rec.docId, oldDoc)
        coll.del(rec.docId)
      if rec.docId in result.versions[rec.collection]: result.versions[rec.collection].del(rec.docId)

## Get the current value of a document by collection and id.
## Returns nil if not found. Cached reads are served from the LRU cache.
proc get*(db: GlenDB; collection, docId: string): Value =
  let key = collection & ":" & docId
  let cached = db.cache.get(key)
  if cached != nil:
    return cached.clone()
  acquireRead(db.rw)
  if collection in db.collections and docId in db.collections[collection]:
    let v = db.collections[collection][docId]
    db.cache.put(key, v)
    let cloned = v.clone()
    releaseRead(db.rw)
    return cloned
  releaseRead(db.rw)

# Borrowed (non-cloned) read. Caller must not mutate returned Value.
proc getBorrowed*(db: GlenDB; collection, docId: string): Value =
  let key = collection & ":" & docId
  let cached = db.cache.get(key)
  if cached != nil:
    return cached
  acquireRead(db.rw)
  if collection in db.collections and docId in db.collections[collection]:
    let v = db.collections[collection][docId]
    db.cache.put(key, v)
    releaseRead(db.rw)
    return v
  releaseRead(db.rw)

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
  acquireRead(db.rw)
  if collection in db.collections:
    let coll = db.collections[collection]
    for id in missing:
      if id in coll:
        let v = coll[id]
        db.cache.put(collection & ":" & id, v)
        result.add((id, v.clone()))
  releaseRead(db.rw)

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
  acquireRead(db.rw)
  if collection in db.collections:
    let coll = db.collections[collection]
    for id in missing:
      if id in coll:
        let v = coll[id]
        db.cache.put(collection & ":" & id, v)
        result.add((id, v))
  releaseRead(db.rw)

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
  acquireRead(db.rw)
  if collection in db.collections:
    for id, v in db.collections[collection]:
      db.cache.put(collection & ":" & id, v)
      result.add((id, v.clone()))
  releaseRead(db.rw)

## Borrowed getAll: returns refs without cloning. Caller must not mutate.
proc getBorrowedAll*(db: GlenDB; collection: string): seq[(string, Value)] =
  result = @[]
  acquireRead(db.rw)
  if collection in db.collections:
    for id, v in db.collections[collection]:
      db.cache.put(collection & ":" & id, v)
      result.add((id, v))
  releaseRead(db.rw)

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
  var notifications: seq[(Id, Value)] = @[]
  var fieldNotifications: seq[(Id, Value, Value)] = @[]
  acquireWrite(db.rw)
  if collection notin db.collections:
    db.collections[collection] = initTable[string, Value]()
  if collection notin db.versions:
    db.versions[collection] = initTable[string, uint64]()
  var oldVer = 0'u64
  if docId in db.versions[collection]: oldVer = db.versions[collection][docId]
  let newVer = oldVer + 1
  var stored = value.clone()
  db.wal.append(WalRecord(kind: wrPut, collection: collection, docId: docId, version: newVer, value: stored))
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
  releaseWrite(db.rw)
  for it in notifications:
    db.subs.notify(it[0], it[1])
  for it in fieldNotifications:
    db.subs.notifyFieldChanges(it[0], it[1], it[2])

## Delete a document if it exists. Appends a delete to WAL, removes from
## in-memory state and cache, bumps the version, and notifies subscribers.
proc delete*(db: GlenDB; collection, docId: string) =
  var notifications: seq[(Id, Value)] = @[]
  var fieldNotifications: seq[(Id, Value, Value)] = @[]
  acquireWrite(db.rw)
  if collection in db.collections and docId in db.collections[collection]:
    var ver = 1'u64
    if collection in db.versions and docId in db.versions[collection]:
      ver = db.versions[collection][docId] + 1
    db.wal.append(WalRecord(kind: wrDelete, collection: collection, docId: docId, version: ver))
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
  acquireWrite(db.rw)
  if t.state != tsActive:
    releaseWrite(db.rw)
    return CommitResult(status: csInvalid, message: "Transaction not active")
  # validate
  for k, ver in t.readVersions:
    let parts = k.split(":")
    if parts.len != 2: continue
    let cur = db.currentVersion(parts[0], parts[1])
    if cur != ver:
      t.state = tsRolledBack
      releaseWrite(db.rw)
      return CommitResult(status: csConflict, message: "Version mismatch for " & k)
  # apply writes
  var walRecs: seq[WalRecord] = @[]
  for key, w in t.writes:
    let collection = key[0]
    let docId = key[1]
    if w.kind == twDelete:
      if collection in db.collections and docId in db.collections[collection]:
        let newVer = db.currentVersion(collection, docId) + 1
        walRecs.add(WalRecord(kind: wrDelete, collection: collection, docId: docId, version: newVer))
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
    else:
      if collection notin db.collections:
        db.collections[collection] = initTable[string, Value]()
      let newVer = db.currentVersion(collection, docId) + 1
      walRecs.add(WalRecord(kind: wrPut, collection: collection, docId: docId, version: newVer, value: w.value))
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
  if walRecs.len > 0:
    db.wal.appendMany(walRecs)
  t.state = tsCommitted
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

# Snapshot trigger (simple: write all collections)
## Write snapshots for all collections to durable storage.
proc snapshotAll*(db: GlenDB) =
  acquireWrite(db.rw)
  defer: releaseWrite(db.rw)
  for collection, docs in db.collections:
    writeSnapshot(db.dir, collection, docs)

## Create an equality index on a field path (e.g., "name" or "profile.age").
proc createIndex*(db: GlenDB; collection: string; name: string; fieldPath: string) =
  acquireWrite(db.rw)
  defer: releaseWrite(db.rw)
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
  acquireWrite(db.rw)
  defer: releaseWrite(db.rw)
  if collection in db.indexes and name in db.indexes[collection]:
    db.indexes[collection].del(name)

## Query documents by equality on an indexed field. Optional limit.
proc findBy*(db: GlenDB; collection: string; indexName: string; keyValue: Value; limit = 0): seq[(string, Value)] =
  acquireRead(db.rw)
  defer: releaseRead(db.rw)
  if collection notin db.indexes or indexName notin db.indexes[collection]: return @[]
  let idx = db.indexes[collection][indexName]
  result = @[]
  for id in idx.findEq(keyValue, limit):
    if collection in db.collections and id in db.collections[collection]:
      result.add((id, db.collections[collection][id]))

## Range query on a single-field index, with order and limit.
proc rangeBy*(db: GlenDB; collection: string; indexName: string; minVal, maxVal: Value; inclusiveMin = true; inclusiveMax = true; limit = 0; asc = true): seq[(string, Value)] =
  acquireRead(db.rw)
  defer: releaseRead(db.rw)
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
  acquireWrite(db.rw)
  defer: releaseWrite(db.rw)
  for collection, docs in db.collections:
    writeSnapshot(db.dir, collection, docs)
  # Reset WAL after snapshot to start a new, empty log
  if db.wal != nil:
    db.wal.reset()

# Close database resources
## Close database resources (WAL file handles).
proc close*(db: GlenDB) =
  acquireWrite(db.rw)
  defer: releaseWrite(db.rw)
  if db.wal != nil:
    db.wal.close()

proc cacheStats*(db: GlenDB): CacheStats =
  db.cache.stats()

proc setWalSync*(db: GlenDB; mode: WalSyncMode; flushEveryBytes = 0) =
  acquireWrite(db.rw)
  defer: releaseWrite(db.rw)
  if db.wal != nil:
    db.wal.setSyncPolicy(mode, flushEveryBytes)

