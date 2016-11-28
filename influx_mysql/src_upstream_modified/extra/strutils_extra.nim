# strutils_extra.nim
# By Philip Wernersbach <philip.wernersbach@gmail.com>
#
# Licensed under the MIT License
# 
# MIT License
#
# Copyright (c) 2016 Philip Wernersbach
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

import parseutils_extra as parseutils

proc parseUInt*(s: string): uint {.noSideEffect, procvar, extern: "nsuParseUInt".} =
  ## Parses a decimal unsigned integer value contained in `s`.
  ##
  ## If `s` is not a valid integer, `ValueError` is raised.
  var L = parseutils.parseUInt(s, result, 0)
  if L != s.len or L == 0:
    raise newException(ValueError, "invalid unsigned integer: " & s)

proc parseBiggestUInt*(s: string): uint64 {.noSideEffect, procvar, extern: "nsuParseBiggestUInt".} =
  ## Parses a decimal unsigned integer value contained in `s`.
  ##
  ## If `s` is not a valid integer, `ValueError` is raised.
  var L = parseutils.parseBiggestUInt(s, result, 0)
  if L != s.len or L == 0:
    raise newException(ValueError, "invalid unsigned integer: " & s)
