# influx_line_protocol_to_sql.nim
# Part of influx-mysql by Philip Wernersbach <philip.wernersbach@gmail.com>
#
# Copyright (c) 2017, Philip Wernersbach
#
# The source code in this file is licensed under the 2-Clause BSD License.
# See the LICENSE file in this project's root directory for the license
# text.

import strutils
import hashes as hashes
import tables
import strtabs
import os

import stdlib_extra
import reflists

#const QUERY_LANG_LEN = "INSERT INTO  (  ) VALUES (  );".len

const MYSQL_BIGINT_CHAR_LEN* = 20

type
    SQLEntryValues* = tuple
        order: OrderedTableRef[ref string, int] not nil
        entries: SinglyLinkedRefList[seq[string]] not nil

    SQLTableInsert* = tuple
        firstEntry: bool
        order: OrderedTableRef[string, int] not nil
        sql: string not nil

    LineProtocolBufferObjectPool* = tuple
        freeBstring: int
        bstring: seq[string]
        keyAndTagsList: seq[int]
        fieldsList: seq[int]

    SQLInsertType* {.pure.} = enum
        NONE
        INSERT,
        REPLACE

    SQLInsertTypeInvalidException = object of ValueError

when not compileOption("threads"):
    var booleanTrueValue = "TRUE"
    var booleanFalseValue = "FALSE"

    shallow(booleanTrueValue)
    shallow(booleanFalseValue)
else:
    var booleanTrueValue {.threadvar.}: string
    var booleanFalseValue {.threadvar.}: string

const MYSQL_DEFAULT_MAX_ALLOWED_PACKET = 2097152

# sqlbuffersize sets the initial size of the SQL INSERT query buffer for schemaless
# POST /write commands.
#
# Only one SQL INSERT query buffer of this size is allocated per POST /write command.
#
# The default size is MySQL's default max_allowed_packet value. Setting this to a higher
# size will improve memory usage for INSERTs larger than the size, at the expense of
# overallocating memory for INSERTs smaller than the size.
when getEnv("sqlbuffersize") == "":
    const SQL_BUFFER_SIZE* = MYSQL_DEFAULT_MAX_ALLOWED_PACKET
else:
    const SQL_BUFFER_SIZE* = getEnv("sqlbuffersize").parseInt

# schemafulsqlbuffersize sets the initial size of the SQL INSERT query buffer for
# schemaful POST /write commands.
#
# Each measurement in a POST /write command will be allocated its own SQL INSERT query
# buffer of this size. So the size of the allocated SQL INSERT query buffers will be
# SCHEMAFUL_SQL_BUFFER_SIZE * (number of measurements in POST /write command).
#
# The tuning tradeoffs of SCHEMAFUL_SQL_BUFFER_SIZE are the same as the ones for
# SQL_BUFFER_SIZE.
when getEnv("schemafulsqlbuffersize") == "":
    const SCHEMAFUL_SQL_BUFFER_SIZE* = MYSQL_DEFAULT_MAX_ALLOWED_PACKET
else:
    const SCHEMAFUL_SQL_BUFFER_SIZE* = getEnv("schemafulsqlbuffersize").parseInt

template hash(x: ref string): Hash =
    hashes.hash(cast[pointer](x))

when compileOption("threads"):
    proc initInfluxLineProtocolToSQL*() =
        if booleanTrueValue == nil:
            booleanTrueValue = "TRUE"
            shallow(booleanTrueValue)

        if booleanFalseValue == nil:
            booleanFalseValue = "FALSE"
            shallow(booleanFalseValue)

proc getTokenInto*(entry: string, result: var string, tokenEnd: set[char], start: int, stop = -1) =
    var escaped = false
    var quoted = false

    let entryLen = if stop >= 0:
            stop
        else:
            entry.len

    for i in countUp(start, entryLen - 1):
        if not quoted:
            if not escaped:
                if entry[i] == '\\':
                    escaped = true
                elif entry[i] == '"':
                    quoted = true
                elif entry[i] in tokenEnd:
                    let resultLen = i - start

                    result.setLen(resultLen)
                    copyMem(addr(result[0]), unsafeAddr(entry[start]), resultLen)

                    return
            else:
                escaped = false
        elif entry[i] == '"':
            quoted = false

    let resultLen = entryLen - start

    result.setLen(resultLen)
    copyMem(addr(result[0]), unsafeAddr(entry[start]), resultLen)

proc getTokenLen*(entry: string, tokenEnd: set[char], start: int, stop = -1): int =
    var escaped = false
    var quoted = false

    let entryLen = if stop >= 0:
            stop
        else:
            entry.len

    for i in countUp(start, entryLen - 1):
        if not quoted:
            if not escaped:
                if entry[i] == '\\':
                    escaped = true
                elif entry[i] == '"':
                    quoted = true
                elif entry[i] in tokenEnd:
                    result = i - start
                    return
            else:
                escaped = false
        elif entry[i] == '"':
            quoted = false

    result = entryLen - start

template getTokenInto*(entry: string, result: var string, tokenEnd: char, start: int, stop = -1) =
    entry.getTokenInto(result, {tokenEnd}, start, stop)

template getTokenLen*(entry: string, tokenEnd: char, start: int, stop = -1): int =
    entry.getTokenLen({tokenEnd}, start, stop)

proc tokenIdxsInto(entry: string, result: var seq[int], tokenEnd: char, start = 0, stop = -1) =
    var i = start
    var tokensLen = 0

    let entryLen = if stop >= 0:
            stop
        else:
            entry.len
    
    # Iterate once to find out how many tokens there are in the string
    while i < entryLen:
        i += entry.getTokenLen(tokenEnd, i, entryLen) + 1
        tokensLen += 1

    i = start
    result.setLen(tokensLen)

    # Iterate again to build the result.
    for pos in countUp(0, tokensLen-1):
        result[pos] = i

        i += entry.getTokenLen(tokenEnd, i, entryLen) + 1

type
    InfluxValueType {.pure.} = enum
        INTEGER,
        FLOAT,
        BOOLEAN_TRUE,
        BOOLEAN_FALSE,
        STRING

proc valueType(value: string): InfluxValueType =
    let valueLen = value.len

    case value[valueLen - 1]:
    of 'i':
        result = InfluxValueType.INTEGER
    of '"':
        result = InfluxValueType.STRING
    of 't', 'T':
        result = InfluxValueType.BOOLEAN_TRUE
    of 'f', 'F':
        result = InfluxValueType.BOOLEAN_FALSE
    else:
        case value:
        of "true", "TRUE":
            result = InfluxValueType.BOOLEAN_TRUE
        of "false", "FALSE":
            result = InfluxValueType.BOOLEAN_FALSE
        else:
            result = InfluxValueType.FLOAT

template ensureSeqHasIndex[T](s: ref seq[T], currentLength: var int, i: int) =
    if currentLength <= i:
        let iLen = i + 1

        s[].setLen(iLen)
        currentLength = iLen

template ensureSeqHasIndex[T](s: var seq[T], currentLength: var int, i: int) =
    if currentLength <= i:
        let iLen = i + 1

        s.setLen(iLen)
        currentLength = iLen

template ensureSeqHasIndexAndString(s: var seq[string], currentLength: var int, i: int) =
    if currentLength <= i:
        let iLen = i + 1

        s.setLen(iLen)

        for pos in countUp(currentLength, i):
            s[pos] = newStringOfCap(64)

        currentLength = iLen

proc lineProtocolToSQLEntryValues*(entry: string, result: var Table[ref string, SQLEntryValues], internedStrings: var Table[string, ref string],
        bop: var LineProtocolBufferObjectPool) {.gcsafe.} =

    let keyAndTagsLen = entry.getTokenLen(' ', 0)

    let fieldsStart = keyAndTagsLen + 1
    let fieldsLen = entry.getTokenLen(' ', fieldsStart)
    let fieldsEnd = fieldsStart + fieldsLen

    # bop.bstring[0] = timestamp
    entry.getTokenInto(bop.bstring[0], ' ', fieldsEnd + 1)

    # bop.bstring[1] = key
    entry.getTokenInto(bop.bstring[1], {',', ' '}, 0)

    let timeInterned = internedStrings["time"]

    entry.tokenIdxsInto(bop.keyAndTagsList, ',', bop.bstring[1].len + 1, keyAndTagsLen)
    let keyAndTagsListLen = bop.keyAndTagsList.len

    entry.tokenIdxsInto(bop.fieldsList, ',', fieldsStart, fieldsEnd)
    let fieldsListLen = bop.fieldsList.len

    var keyInterned = internedStrings.getOrDefault(bop.bstring[1])
    if keyInterned == nil:
        new(keyInterned)
        keyInterned[] = bop.bstring[1]

        shallow(keyInterned[])

        internedStrings[keyInterned[]] = keyInterned

    if not result.hasKey(keyInterned):
        result[keyInterned] = (order: cast[OrderedTableRef[ref string, int] not nil](newOrderedTable[ref string, int]()), 
                        entries: newSinglyLinkedRefList[seq[string]]())

    let order = result[keyInterned].order

    # The length of the entry values seq is the total number of datapoints, if you will:
    # <number of tags> + <number of fields> + <one for the timestamp>
    var entryValuesLen = max(keyAndTagsListLen + fieldsListLen + 1, order.len)

    var entryValues: ref seq[string]
    new(entryValues)
    entryValues[] = newSeq[string](entryValuesLen)

    let entryValuesPos = order.mgetOrPut(timeInterned, order.len)

    entryValues.ensureSeqHasIndex(entryValuesLen, entryValuesPos)
    entryValues[entryValuesPos] = newStringOfCap(bop.bstring[0].len + 14 + 29)
    entryValues[entryValuesPos].add("FROM_UNIXTIME(")
    entryValues[entryValuesPos].add(bop.bstring[0])
    entryValues[entryValuesPos].add("*0.000000001)")
    shallow(entryValues[entryValuesPos])

    for tagAndValuePos in bop.keyAndTagsList.items:
        # bop.bstring[0] = tag
        entry.getTokenInto(bop.bstring[0], '=', tagAndValuePos, keyAndTagsLen)

        let bstring0Len = bop.bstring[0].len

        var tagInterned = internedStrings.getOrDefault(bop.bstring[0])
        if tagInterned == nil:
            new(tagInterned)
            tagInterned[] = bop.bstring[0]

            shallow(tagInterned[])

            internedStrings[tagInterned[]] = tagInterned

        let entryValuesPos = order.mgetOrPut(tagInterned, order.len)

        # bop.bstring[1] = value
        entryValues.ensureSeqHasIndex(entryValuesLen, entryValuesPos)
        entry.getTokenInto(bop.bstring[1], ',', tagAndValuePos + bstring0Len + 1, keyAndTagsLen)

        let bstring1Len = bop.bstring[1].len

        entryValues[entryValuesPos] = newStringOfCap(bstring1Len + bstring1Len shr 2)
        bop.bstring[1].sqlEscapeInto(entryValues[entryValuesPos])
        shallow(entryValues[entryValuesPos])

    for nameAndValuePos in bop.fieldsList.items:
        # bop.bstring[0] = name
        entry.getTokenInto(bop.bstring[0], '=', nameAndValuePos, fieldsEnd)

        # bop.bstring[1] = value
        entry.getTokenInto(bop.bstring[1], ',', nameAndValuePos + bop.bstring[0].len + 1, fieldsEnd)

        var nameInterned = internedStrings.getOrDefault(bop.bstring[0])
        if nameInterned == nil:
            new(nameInterned)
            nameInterned[] = bop.bstring[0]

            shallow(nameInterned[])

            internedStrings[nameInterned[]] = nameInterned

        let entryValuesPos = order.mgetOrPut(nameInterned, order.len)
        entryValues.ensureSeqHasIndex(entryValuesLen, entryValuesPos)

        case bop.bstring[1].valueType:
        of InfluxValueType.INTEGER:
            entryValues[entryValuesPos] = bop.bstring[1][0..bop.bstring[1].len-2]
        of InfluxValueType.STRING:
            let bstring1Len = bop.bstring[1].len

            entryValues[entryValuesPos] = newStringOfCap(bstring1Len + bstring1Len shr 2)
            bop.bstring[1].sqlReescapeInto(entryValues[entryValuesPos])
        of InfluxValueType.FLOAT:
            entryValues[entryValuesPos] = bop.bstring[1]
        of InfluxValueType.BOOLEAN_TRUE:
            entryValues[entryValuesPos].shallowCopy(booleanTrueValue)
        of InfluxValueType.BOOLEAN_FALSE:
            entryValues[entryValuesPos].shallowCopy(booleanFalseValue)

        shallow(entryValues[entryValuesPos])

    result[keyInterned].entries.append(entryValues)

proc newSQLTableInsert(tableName: string, insertType: SQLInsertType): SQLTableInsert {.inline.} =
    result = (firstEntry: true, order: cast[OrderedTableRef[string, int] not nil](newOrderedTable[string, int]()),
        sql: cast[string not nil](newStringOfCap(SCHEMAFUL_SQL_BUFFER_SIZE)))

    result.order["time"] = result.order.len

    # Add header
    case insertType:
    of SQLInsertType.INSERT:
        result.sql.add("INSERT INTO ")
    of SQLInsertType.REPLACE:
        result.sql.add("REPLACE INTO ")
    of SQLInsertType.NONE:
        raise newException(SQLInsertTypeInvalidException, "No SQL insert type specified!")

    result.sql.add(tableName)
    result.sql.add(" (")

proc lineProtocolToSQLTableInsert*(entry: string, result: var Table[string, ref SQLTableInsert], entryValues: var seq[string],
    bop: var LineProtocolBufferObjectPool, insertType: SQLInsertType) {.gcsafe.} =

    var schemaLine = false
    var bstringSeqLen = bop.bstring.len

    let keyAndTagsLen = entry.getTokenLen(' ', 0)

    let fieldsStart = keyAndTagsLen + 1
    let fieldsLen = entry.getTokenLen(' ', fieldsStart)
    let fieldsEnd = fieldsStart + fieldsLen

    bop.freeBstring = 2

    # bop.bstring[0] = timestamp
    entry.getTokenInto(bop.bstring[0], ' ', fieldsEnd + 1)

    # bop.bstring[1] = key
    entry.getTokenInto(bop.bstring[1], {',', ' '}, 0)

    entry.tokenIdxsInto(bop.keyAndTagsList, ',', bop.bstring[1].len + 1, keyAndTagsLen)
    let keyAndTagsListLen = bop.keyAndTagsList.len

    entry.tokenIdxsInto(bop.fieldsList, ',', fieldsStart, fieldsEnd)
    let fieldsListLen = bop.fieldsList.len

    if not result.hasKey(bop.bstring[1]):
        var newInsert: ref SQLTableInsert
        new(newInsert)
        newInsert[] = newSQLTableInsert(bop.bstring[1], insertType)

        result[bop.bstring[1]] = newInsert
        schemaLine = true

    var insert = result[bop.bstring[1]]
    let order = insert.order

    # The length of the entry values seq is the total number of datapoints, if you will:
    # <number of tags> + <number of fields> + <one for the timestamp>
    #
    # We set the length of entryValues to one before setting it to the real length in
    # order to set the other indexes of entryValues to nil.
    var entryValuesLen = max(keyAndTagsListLen + fieldsListLen + 1, order.len)
    entryValues.setLen(1)
    entryValues.setLen(entryValuesLen)

    let entryValuesPos = order.mgetOrPut("time", order.len)
    entryValues.ensureSeqHasIndex(entryValuesLen, entryValuesPos)

    # The length of the "time" object is already set to the maximum possible, given MySQL's
    # range restrictions on BIGINTs. So we just set the length to zero without pre-allocating
    # first.
    entryValues[entryValuesPos].setLen(0)
    entryValues[entryValuesPos].add("FROM_UNIXTIME(")
    entryValues[entryValuesPos].add(bop.bstring[0])
    entryValues[entryValuesPos].add("*0.000000001)")

    for tagAndValuePos in bop.keyAndTagsList.items:
        let nextFreeBstring = bop.freeBstring + 1

        # bop.bstring[0] = tag
        entry.getTokenInto(bop.bstring[0], '=', tagAndValuePos, keyAndTagsLen)

        let entryValuesPos = order.mgetOrPut(bop.bstring[0], order.len)

        entryValues.ensureSeqHasIndex(entryValuesLen, entryValuesPos)

        # bop.bstring[1] = unescaped value
        entry.getTokenInto(bop.bstring[1], ',', tagAndValuePos + bop.bstring[0].len + 1, keyAndTagsLen)
        
        # bop.bstring[bop.freeBstring] = escaped value
        bop.bstring[1].sqlEscapeInto(bop.bstring[bop.freeBstring])
        entryValues[entryValuesPos].shallowCopy(bop.bstring[bop.freeBstring])

        bop.bstring.ensureSeqHasIndexAndString(bstringSeqLen, nextFreeBstring)
        bop.freeBstring = nextFreeBstring

    for nameAndValuePos in bop.fieldsList.items:
        # bop.bstring[0] = name
        entry.getTokenInto(bop.bstring[0], '=', nameAndValuePos, fieldsEnd)

        # bop.bstring[bop.freeBstring] = value
        entry.getTokenInto(bop.bstring[bop.freeBstring], ',', nameAndValuePos + bop.bstring[0].len + 1, fieldsEnd)

        let entryValuesPos = order.mgetOrPut(bop.bstring[0], order.len)
        entryValues.ensureSeqHasIndex(entryValuesLen, entryValuesPos)

        case bop.bstring[bop.freeBstring].valueType:
        of InfluxValueType.INTEGER:
            let nextFreeBstring = bop.freeBstring + 1

            bop.bstring[bop.freeBstring].setLen(bop.bstring[bop.freeBstring].len-1)
            entryValues[entryValuesPos].shallowCopy(bop.bstring[bop.freeBstring])

            bop.bstring.ensureSeqHasIndexAndString(bstringSeqLen, nextFreeBstring)
            bop.freeBstring = nextFreeBstring
        of InfluxValueType.STRING:
            let nextFreeBstring = bop.freeBstring + 1

            bop.bstring[bop.freeBstring].sqlReescapeInto(bop.bstring[1])

            let reescapedLen = bop.bstring[1].len

            bop.bstring[bop.freeBstring].setLen(reescapedLen)
            entryValues[entryValuesPos].shallowCopy(bop.bstring[bop.freeBstring])
            copyMem(addr(entryValues[entryValuesPos][0]), addr(bop.bstring[1][0]), reescapedLen)

            bop.bstring.ensureSeqHasIndexAndString(bstringSeqLen, nextFreeBstring)
            bop.freeBstring = nextFreeBstring
        of InfluxValueType.FLOAT:
            let nextFreeBstring = bop.freeBstring + 1

            entryValues[entryValuesPos].shallowCopy(bop.bstring[bop.freeBstring])

            bop.bstring.ensureSeqHasIndexAndString(bstringSeqLen, nextFreeBstring)
            bop.freeBstring = nextFreeBstring
        of InfluxValueType.BOOLEAN_TRUE:
            entryValues[entryValuesPos].shallowCopy(booleanTrueValue)
        of InfluxValueType.BOOLEAN_FALSE:
            entryValues[entryValuesPos].shallowCopy(booleanFalseValue)

    if not schemaLine:
        # Add column values
        if not insert.firstEntry:
            insert.sql.add(",")
        else:
            insert.firstEntry = false

        insert.sql.add("(")

        for columnPos in order.values:
            if columnPos > 0:
                insert.sql.add(",")

            if (columnPos < entryValuesLen) and (entryValues[columnPos] != nil):
                insert.sql.add(entryValues[columnPos])
            else:
                insert.sql.add("NULL")

        insert.sql.add(")")
    else:
        var first = true

        # Add column names to header
        for columnName in order.keys:
            if not first:
                insert.sql.add(",")
            else:
                first = false

            insert.sql.add(columnName)

        insert.sql.add(") VALUES ")

template addSQLStatementDelimiter*(result: var string) =
    # Add SQL statement delimiter
    result.add(";\n")

proc sqlEntryValuesToSQL*(kv: tuple[key: ref string, value: SQLEntryValues], result: var string, insertType: SQLInsertType) =
    # Add header
    case insertType:
    of SQLInsertType.INSERT:
        result.add("INSERT INTO ")
    of SQLInsertType.REPLACE:
        result.add("REPLACE INTO ")
    of SQLInsertType.NONE:
        raise newException(SQLInsertTypeInvalidException, "No SQL insert type specified!")

    result.add(kv.key[])

    result.add(" (")

    # Add column names to header
    var first = true
    for columnName in kv.value.order.keys:
        if not first:
            result.add(",")
        else:
            first = false

        result.add(columnName[])

    # Add column values
    result.add(") VALUES ")
    
    first = true
    for entry in kv.value.entries.items:
        let entryLen = entry[].len

        if not first:
            result.add(",")
        else:
            first = false

        result.add("(")
        
        for columnPos in kv.value.order.values:
            if columnPos > 0:
                result.add(",")

            if (columnPos < entryLen) and (entry[columnPos] != nil):
                result.add(entry[columnPos])
            else:
                result.add("NULL")

        result.add(")")

    result.addSQLStatementDelimiter
