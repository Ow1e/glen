# Glen error hierarchy

type
  GlenError* = object of CatchableError
  TxnConflictError* = object of GlenError
  NotFoundError* = object of GlenError
  ValidationError* = object of GlenError
  CodecError* = object of GlenError
  SnapshotError* = object of GlenError
  WalError* = object of GlenError

proc raiseConflict*() = raise newException(TxnConflictError, "Transaction conflict")
proc raiseNotFound*(msg: string) = raise newException(NotFoundError, msg)
proc raiseValidation*(msg: string) = raise newException(ValidationError, msg)
proc raiseCodec*(msg: string) = raise newException(CodecError, msg)
proc raiseSnapshot*(msg: string) = raise newException(SnapshotError, msg)
proc raiseWal*(msg: string) = raise newException(WalError, msg)
