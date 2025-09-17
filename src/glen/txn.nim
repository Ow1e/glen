# Glen optimistic transactions

import std/[tables]
import glen/types

# Transaction model: snapshot versions captured at begin; staging area of mutations.
# Commit checks versions match current before applying.

type
  TxnState* = enum tsActive, tsCommitted, tsRolledBack

  TxnWriteKind* = enum twPut, twDelete

  TxnWrite* = object
    kind*: TxnWriteKind
    value*: Value

  CommitStatus* = enum csOk, csConflict, csInvalid

  CommitResult* = object
    status*: CommitStatus
    message*: string

  Txn* = ref object
    state*: TxnState
    readVersions*: Table[string, uint64]   # key -> version observed
    writes*: Table[string, TxnWrite]       # key -> write op

proc newTxn*(): Txn =
  Txn(state: tsActive, readVersions: initTable[string, uint64](), writes: initTable[string, TxnWrite]())

proc assertActive(t: Txn) =
  if t.state != tsActive: raise newException(ValueError, "Transaction not active")

proc keyFor(collection, docId: string): string = collection & ":" & docId

proc recordRead*(t: Txn; id: Id) =
  assertActive(t)
  let k = keyFor(id.collection, id.docId)
  if k notin t.readVersions:
    t.readVersions[k] = id.version

proc stagePut*(t: Txn; id: Id; value: Value) =
  assertActive(t)
  let k = keyFor(id.collection, id.docId)
  t.writes[k] = TxnWrite(kind: twPut, value: value)

proc stageDelete*(t: Txn; collection, docId: string) =
  assertActive(t)
  let k = keyFor(collection, docId)
  t.writes[k] = TxnWrite(kind: twDelete)

proc rollback*(t: Txn) =
  assertActive(t); t.state = tsRolledBack

# Commit logic will be in db module to access live store versions.

proc ok*(r: CommitResult): bool = r.status == csOk
