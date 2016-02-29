import hashes as hashes

template hash*(x: ref string): Hash =
    hashes.hash(cast[pointer](x))

proc strdup*(s: var string): string =
    result = newString(s.len)
    copyMem(addr(result[0]), addr(s[0]), result.len)

proc strdup*(s: var cstring): string =
    result = newString(s.len)
    copyMem(addr(result[0]), addr(s[0]), result.len)
