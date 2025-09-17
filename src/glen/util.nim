# Utility helpers for Glen
import std/[os, times]

proc nowMillis*(): int64 =
  (epochTime() * 1000).int64

proc ensureDir*(path: string) =
  if not dirExists(path): createDir(path)
