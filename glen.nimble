# Glen document database nimble spec
version       = "0.1.0"
author        = "Glen"
description   = "Glen: A wickedly fast embedded document database with subscriptions and transactions"
license       = "MIT"
srcDir        = "src"

# Minimum Nim version
requires "nim >= 1.6.0"

# No external deps for core; future: zstd, etc.

bin           = @["glen"]

proc runTest(file: string) =
  exec "nim c -r --path:src " & file

const testFiles = @[
  "tests/test_db.nim",
  "tests/test_wal_snapshot.nim",
  "tests/test_subscriptions.nim",
  "tests/test_cache.nim",
  "tests/test_codec.nim"
]

task test, "Run test suite":
  for f in testFiles:
    runTest(f)

task docs, "Generate API docs":
  exec "nim doc --project --outdir:docs --path:src src/glen/glen.nim"
