# Glen root module re-exporting public API

import std/[tables, locks]
import glen/types
import glen/codec
import glen/wal
import glen/storage
import glen/cache
import glen/subscription
import glen/txn
import glen/db
import glen/util
import glen/index

# Public exports

export types, codec, wal, storage, cache, subscription, txn, db, util, index

# Placeholder openDatabase
proc openDatabase*(path: string): GlenDB =
  ## Open or create a Glen database at the given path.
  result = newGlenDB(path)
