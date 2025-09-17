# Glen subscription system
# Allows subscribing to (collection, docId) changes.

import std/[tables, locks]
import glen/types

type
  SubscriberCallback* = proc (id: Id; newValue: Value) {.closure.}

  SubEntry = ref object
    key: string
    callbacks: seq[SubscriberCallback]

  SubscriptionManager* = ref object
    lock: Lock
    subs: Table[string, SubEntry]

  SubscriptionHandle* = object
    key*: string
    index*: int

proc newSubscriptionManager*(): SubscriptionManager =
  result = SubscriptionManager(subs: initTable[string, SubEntry]())
  initLock(result.lock)

proc makeKey(collection, docId: string): string = collection & ":" & docId

proc subscribe*(sm: SubscriptionManager; collection, docId: string; cb: SubscriberCallback): SubscriptionHandle =
  acquire(sm.lock)
  let key = makeKey(collection, docId)
  if key notin sm.subs:
    sm.subs[key] = SubEntry(key: key, callbacks: @[])
  sm.subs[key].callbacks.add(cb)
  let idx = sm.subs[key].callbacks.len - 1
  release(sm.lock)
  result = SubscriptionHandle(key: key, index: idx)

converter toSubscriberCallback*(cb: proc (id: Id; newValue: Value)): SubscriberCallback =
  proc (id: Id; newValue: Value) {.closure.} = cb(id, newValue)

proc unsubscribe*(sm: SubscriptionManager; h: SubscriptionHandle) =
  acquire(sm.lock)
  if h.key in sm.subs:
    var entry = sm.subs[h.key]
    if h.index >= 0 and h.index < entry.callbacks.len:
      entry.callbacks[h.index] = nil
  release(sm.lock)

proc notify*(sm: SubscriptionManager; id: Id; newValue: Value) =
  let key = makeKey(id.collection, id.docId)
  var callbacks: seq[SubscriberCallback] = @[]
  acquire(sm.lock)
  if key in sm.subs:
    for cb in sm.subs[key].callbacks:
      if cb != nil:
        callbacks.add(cb)
  release(sm.lock)
  for cb in callbacks:
    cb(id, newValue)
