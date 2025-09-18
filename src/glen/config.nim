import std/[os, parseutils]

type
  GlenConfig* = object
    maxStringOrBytes*: int
    maxArrayLen*: int
    maxObjectFields*: int

let defaultMaxStringOrBytes = 16 * 1024 * 1024
let defaultMaxArrayLen = 1_000_000
let defaultMaxObjectFields = 1_000_000

proc parseIntEnv(name: string; defaultValue: int): int =
  let v = getEnv(name)
  if v.len == 0: return defaultValue
  var n: int
  if parseInt(v, n) == v.len and n > 0: n else: defaultValue

proc loadConfig*(): GlenConfig =
  GlenConfig(
    maxStringOrBytes: parseIntEnv("GLEN_MAX_STRING_OR_BYTES", defaultMaxStringOrBytes),
    maxArrayLen: parseIntEnv("GLEN_MAX_ARRAY_LEN", defaultMaxArrayLen),
    maxObjectFields: parseIntEnv("GLEN_MAX_OBJECT_FIELDS", defaultMaxObjectFields)
  )


