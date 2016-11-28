# overflowChecks doesn't work with uint64
proc rawParseUInt(s: string, b: var uint64, start = 0): int =
  var
    res = 0'u64
    prev = 0'u64
    i = start
  if s[i] == '+': inc(i) # Allow 
  if s[i] in {'0'..'9'}:
    b = 0
    while s[i] in {'0'..'9'}:
      prev = res
      res = res * 10 + (ord(s[i]) - ord('0')).uint64
      if prev > res:
        return 0 # overflowChecks emulation
      inc(i)
      while s[i] == '_': inc(i) # underscores are allowed and ignored
    b = res
    result = i - start

proc parseBiggestUInt*(s: string, number: var uint64, start = 0): int {.extern: "npuParseBiggestUInt", noSideEffect.} =
  ## parses an unsigned integer starting at `start` and stores the value into `number`.
  ## Result is the number of processed chars or 0 if there is no integer or overflow detected.
  var res: uint64
  # use 'res' for exception safety (don't write to 'number' in case of an
  # overflow exception):
  result = rawParseUInt(s, res, start)
  number = res

# Workaround for high(uint)
proc highUInt(): uint64 =
  when sizeof(uint) == 4:
    0xFFFFFFFF'u64
  elif sizeof(uint) == 8:
    0xFFFFFFFFFFFFFFFF'u64
  else:
    {.fatal: "Unknoun uint size: " & $sizeof(uint).}

proc parseUInt*(s: string, number: var uint, start = 0): int {.extern: "npuParseUInt", noSideEffect.} =
  ## parses an unsigned integer starting at `start` and stores the value into `number`.
  ## Result is the number of processed chars or 0 if there is no integer.
  ## Result is the number of processed chars or 0 if there is no integer or overflow detected.
  var res: uint64
  result = parseBiggestUInt(s, res, start)
  if (sizeof(uint) <= 4) and
      (res > highUInt()):
    raise newException(OverflowError, "overflow")
  elif result != 0:
    number = uint(res)
