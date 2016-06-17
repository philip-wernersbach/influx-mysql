import strutils
import parseutils as parseutils
import hashes as hashes

template hash*(x: ref string): Hash =
    hashes.hash(cast[pointer](x))

template hash*(x: uint64): Hash =
  ## efficient hashing of uint64 integers
  Hash(uint32(x))

proc strdup*(s: var string): string =
    result = newString(s.len)
    copyMem(addr(result[0]), addr(s[0]), result.len)

proc strdup*(s: var cstring): string =
    result = newString(s.len)
    copyMem(addr(result[0]), addr(s[0]), result.len)

## This section is copied from lib/pure/strutils.nim, and modified. It is under the
## following license:
#
#
#            Nim's Runtime Library
#        (c) Copyright 2012 Andreas Rumpf
#
# =====================================================
# Nim -- a Compiler for Nim. http://nim-lang.org/
#
# Copyright (C) 2006-2015 Andreas Rumpf. All rights reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
# [ MIT license: http://www.opensource.org/licenses/mit-license.php ]
#

proc sqlEscapeInto*(s: string, result: var string) {.noSideEffect.} =
  ## Escapes a string `s`.
  ##
  ## This does these operations (at the same time):
  ## * replaces any ``'`` by ``\'``
  ## * replaces any other character in the set ``{'\0'..'\31', '\128'..'\255'}``
  ##   by ``\xHH`` where ``HH`` is its hexadecimal value.
  ## The procedure has been designed so that its output is usable for many
  ## different common syntaxes. The resulting string is prefixed with
  ## `prefix` and suffixed with `suffix`. Both may be empty strings.
  result.setLen(s.len + s.len shr 2)
  result.setLen(0)
  result.add('\'')
  for c in items(s):
    case c
    of '\0'..'\31', '\128'..'\255':
      add(result, "\\x")
      add(result, toHex(ord(c), 2))
    of '\'': add(result, "\\'")
    else: add(result, c)
  add(result, '\'')

proc sqlReescapeInto*(s: string, result: var string) {.noSideEffect.} =
  ## Unescapes a string `s`.
  ##
  ## This complements `sqlEscapeInto <#sqlEscapeInto>`_ as it performs the opposite
  ## operations.
  ##
  ## If `s` does not begin with ``prefix`` and end with ``suffix`` a
  ## ValueError exception will be raised.
  result.setLen(s.len + s.len shr 2)
  result.setLen(0)
  result.add('\'')
  var i = 1
  if s[0] != '"':
    raise newException(ValueError,
                       "String does not start with a prefix of: \"")
  while true:
    if i == s.len-1: break
    case s[i]
    of '\\':
      case s[i+1]:
      of '\"':
        result.add('\"')
      else:
        result.add('\\')
        result.add(s[i+1])
      inc(i)
    of '\'':
        result.add("\\'")
    of '\0': break
    else:
      result.add(s[i])
    inc(i)
  if s[s.len - 1] != '"':
    raise newException(ValueError,
                       "String does not end with a suffix of: \"")
  result.add('\'')
## End copied section
