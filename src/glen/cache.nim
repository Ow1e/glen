# Glen adaptive LRU cache for documents

import std/[tables, locks]
import glen/types

type
  CacheEntry = ref object
    key: string
    value: Value
    prev, next: CacheEntry
    size: int

  LruCache* = ref object
    map: Table[string, CacheEntry]
    head, tail: CacheEntry
    capacity*: int
    current: int
    lock: Lock
    hits*: int
    misses*: int
    puts*: int
    evictions*: int

proc newLruCache*(capacity: int): LruCache =
  result = LruCache(map: initTable[string, CacheEntry](), capacity: capacity)
  initLock(result.lock)

proc removeNode(c: LruCache; e: CacheEntry) =
  if e.prev != nil: e.prev.next = e.next
  if e.next != nil: e.next.prev = e.prev
  if c.head == e: c.head = e.next
  if c.tail == e: c.tail = e.prev
  e.prev = nil; e.next = nil

proc addFront(c: LruCache; e: CacheEntry) =
  e.next = c.head
  if c.head != nil: c.head.prev = e
  c.head = e
  if c.tail == nil: c.tail = e

proc touch(c: LruCache; e: CacheEntry) =
  removeNode(c, e); addFront(c, e)

proc estimateSize(v: Value): int =
  case v.kind
  of vkNull: 1
  of vkBool: 1
  of vkInt: 9
  of vkFloat: 9
  of vkString: 8 + v.s.len
  of vkBytes: 8 + v.bytes.len
  of vkArray:
    var s = 8
    for it in v.arr: s += estimateSize(it)
    s
  of vkObject:
    var s = 8
    for k, vv in v.obj: s += 8 + k.len + estimateSize(vv)
    s
  of vkId: 32 + v.id.collection.len + v.id.docId.len

proc get*(c: LruCache; key: string): Value =
  acquire(c.lock)
  defer: release(c.lock)
  if key in c.map:
    let e = c.map[key]
    c.touch(e)
    inc c.hits
    return e.value
  inc c.misses

proc put*(c: LruCache; key: string; value: Value) =
  acquire(c.lock)
  defer: release(c.lock)
  let size = estimateSize(value)
  if key in c.map:
    let e = c.map[key]
    c.current -= e.size
    e.value = value; e.size = size
    c.current += size
    c.touch(e)
  else:
    let e = CacheEntry(key: key, value: value, size: size)
    c.map[key] = e
    c.addFront(e)
    c.current += size
    inc c.puts
  while c.current > c.capacity and c.tail != nil:
    let victim = c.tail
    c.removeNode(victim)
    c.map.del(victim.key)
    c.current -= victim.size
    inc c.evictions

proc adjustCapacity*(c: LruCache; newCap: int) =
  acquire(c.lock)
  defer: release(c.lock)
  c.capacity = newCap
  while c.current > c.capacity and c.tail != nil:
    let victim = c.tail
    c.removeNode(victim)
    c.map.del(victim.key)
    c.current -= victim.size

proc del*(c: LruCache; key: string) =
  acquire(c.lock)
  defer: release(c.lock)
  if key in c.map:
    let e = c.map[key]
    c.removeNode(e)
    c.current -= e.size
    c.map.del(key)
