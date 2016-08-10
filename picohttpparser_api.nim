#
#  Copyright (c) 2009-2014 Kazuho Oku, Tokuhiro Matsuno, Daisuke Murase,
#                          Shigeo Mitsunari
# 
#  The software is licensed under either the MIT License (below) or the Perl
#  license.
# 
#  Permission is hereby granted, free of charge, to any person obtaining a copy
#  of this software and associated documentation files (the "Software"), to
#  deal in the Software without restriction, including without limitation the
#  rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
#  sell copies of the Software, and to permit persons to whom the Software is
#  furnished to do so, subject to the following conditions:
# 
#  The above copyright notice and this permission notice shall be included in
#  all copies or substantial portions of the Software.
# 
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
#  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
#  IN THE SOFTWARE.
# 

{.compile: "vendor/picohttpparser/picohttpparser.c".}
{.emit: """#include "vendor/picohttpparser/picohttpparser.h"""".}

import strtabs
import httpcore

#when defined(_MSC_VER): 
#  const 
#    ssize_t* = intptr_t
# $Id: ded2259d5094ae4620381807de0d16f25b6d617c $ 

# contains name and value of a header (name == NULL if is a continuing line
#  of a multiline header 

type
  ssize_t* {.importc, header: "<sys/types.h>".} = BiggestInt
  
  phr_header* {.importc: "struct phr_header", header: "vendor/picohttpparser/picohttpparser.h".} = object 
    name: cstring
    name_len: csize
    value: cstring
    value_len: csize


# returns number of bytes consumed if successful, -2 if request is partial,
#  -1 if failed 

proc phr_parse_request*(buf: cstring; len: csize; `method`: ptr cstring; 
                        method_len: ptr csize; path: ptr cstring; 
                        path_len: ptr csize; minor_version: ptr cint; 
                        headers: ptr phr_header; num_headers: ptr csize; 
                        last_len: csize): cint {.importc, header: "vendor/picohttpparser/picohttpparser.h".}
# ditto 

proc phr_parse_response*(buf: cstring; len: csize; minor_version: ptr cint; 
                         status: ptr cint; msg: cstringArray; 
                         msg_len: ptr csize; headers: ptr phr_header; 
                         num_headers: ptr csize; last_len: csize): cint {.importc, header: "vendor/picohttpparser/picohttpparser.h".}
# ditto 

proc phr_parse_headers*(buf: cstring; len: csize; headers: ptr phr_header; 
                        num_headers: ptr csize; last_len: csize): cint {.importc, header: "vendor/picohttpparser/picohttpparser.h".}
# should be zero-filled before start 

type 
  phr_chunked_decoder* = tuple 
    bytes_left_in_chunk: csize # number of bytes left in current chunk 
    consume_trailer: char    # if trailing headers should be consumed 
    hex_count: char
    state: char


# the function rewrites the buffer given as (buf, bufsz) removing the chunked-
#  encoding headers.  When the function returns without an error, bufsz is
#  updated to the length of the decoded data available.  Applications should
#  repeatedly call the function while it returns -2 (incomplete) every time
#  supplying newly arrived data.  If the end of the chunked-encoded data is
#  found, the function returns a non-negative number indicating the number of
#  octets left undecoded at the tail of the supplied buffer.  Returns -1 on
#  error.
# 

proc phr_decode_chunked*(decoder: ptr phr_chunked_decoder; buf: cstring; 
                         bufsz: ptr csize): ssize_t {.importc, header: "vendor/picohttpparser/picohttpparser.h".}

proc tryParseRequest*(request: string, httpMethod: var string, path: var string, minor_version: var cint,
                   headers: var seq[phr_header]): cint =

    var methodPointer: cstring
    var methodLen: csize
    var pathPointer: cstring
    var pathLen: csize
    var minorVersion: cint
    var previousHeaderBufferLen: csize
    var numberOfHeaders = csize(headers.len)

    let requestLen = request.len
    let requestCstring = cstring(request)
    let requestLenCsize = csize(requestLen)
    let methodPointerAddr = addr(methodPointer)
    let methodLenAddr = addr(methodLen)
    let pathPointerAddr = addr(pathPointer)
    let pathLenAddr = addr(pathLen)
    let minorVersionAddr = addr(minorVersion)
    
    let headersAddr = if numberOfHeaders > 0:
            addr(headers[0])
        else:
            nil

    let numberOfHeadersAddr = addr(numberOfHeaders)

    #var result = phr_parse_request(cstring(request), csize(requestLen), addr(methodPointer), addr(methodLen), addr(pathPointer), addr(pathLen),
    #                      addr(minorVersion), addr(headers[0]), addr(numberOfHeaders), previousHeaderBufferLen)
    {.emit: "`result` = phr_parse_request(`requestCstring`, `requestLen`, (const char **)`methodPointerAddr`, `methodLenAddr`, (const char **)`pathPointerAddr`, `pathLenAddr`, `minorVersionAddr`, `headersAddr`, `numberOfHeadersAddr`, `previousHeaderBufferLen`);" .}

    if (result >= 0):
        if (result == requestLen):
            httpMethod = newString(methodLen)
            copyMem(addr(httpMethod[0]), methodPointer, methodLen)

            path = newString(pathLen)
            copyMem(addr(path[0]), pathPointer, pathLen)

            headers.setLen(numberOfHeaders)
            return
        else:
            result = -255

proc parseRequest*(request: string, httpMethod: var string, path: var string, minor_version: var cint,
                   headers: var seq[phr_header]) =

    let result = request.tryParseRequest(httpMethod, path, minor_version, headers)

    if (result >= 0):
        return
    elif (result == -1):
        raise newException(Exception, "picohttpparser: Parse error!")
    elif (result == -2):
        raise newException(Exception, "picohttpparser: Incomplete request!")
    elif (result == -255):
        raise newException(Exception, "picohttpparser: Request only partially consumed!")
    else:
        raise newException(Exception, "picohttpparser: Unknown error! (Error code: " & $result & ")")

converter toStringTableRef*(x: seq[phr_header]): StringTableRef =
    result = newStringTable(modeCaseSensitive)

    for phr_header in x:
        var name = newString(phr_header.name_len)
        var value = newString(phr_header.value_len)

        copyMem(addr(name[0]), phr_header.name, phr_header.name_len)
        copyMem(addr(value[0]), phr_header.value, phr_header.value_len)

        result[name] = value

converter toHttpHeaders*(x: seq[phr_header]): HttpHeaders =
    result = newHttpHeaders()

    for phr_header in x:
        var name = newString(phr_header.name_len)
        var value = newString(phr_header.value_len)

        copyMem(addr(name[0]), phr_header.name, phr_header.name_len)
        copyMem(addr(value[0]), phr_header.value, phr_header.value_len)

        result.add(name, value)
