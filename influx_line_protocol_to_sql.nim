import strutils
import hashes as hashes
import tables
import strtabs
import os

import reflists

#const QUERY_LANG_LEN = "INSERT INTO  (  ) VALUES (  );".len

type
    SQLEntryValues* = tuple
        order: OrderedTableRef[ref string, int] not nil
        entries: SinglyLinkedRefList[seq[string]] not nil

    SQLTableInsert* = tuple
        firstEntry: bool
        order: OrderedTableRef[string, int] not nil
        sql: string not nil

when not compileOption("threads"):
    var booleanTrueValue = "TRUE"
    var booleanFalseValue = "FALSE"

    shallow(booleanTrueValue)
    shallow(booleanFalseValue)
else:
    var booleanTrueValue {.threadvar.}: string
    var booleanFalseValue {.threadvar.}: string

# sqlbuffersize sets the initial size of the SQL INSERT query buffer for POST /write commands.
# The default size is MySQL's default max_allowed_packet value. Setting this to a higher size
# will improve memory usage for INSERTs larger than the size, at the expense of overallocating
# memory for INSERTs smaller than the size.
when getEnv("sqlbuffersize") == "":
    const SQL_BUFFER_SIZE* = 2097152
else:
    const SQL_BUFFER_SIZE* = getEnv("sqlbuffersize").parseInt

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

proc getToken*(entry: string, tokenEnd: set[char], start: int): string =
    let entryLen = entry.len

    var escaped = false
    var quoted = false
    for i in countUp(start, entryLen - 1):
        if not quoted:
            if not escaped:
                if entry[i] == '\\':
                    escaped = true
                elif entry[i] == '"':
                    quoted = true
                elif entry[i] in tokenEnd:
                    result = entry[start..i-1]
                    return
            else:
                escaped = false
        elif entry[i] == '"':
            quoted = false

    result = entry[start..entryLen-1]

proc getTokenLen*(entry: string, tokenEnd: set[char], start: int): int =
    let entryLen = entry.len

    var escaped = false
    var quoted = false
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

template getToken*(entry: string, tokenEnd: char, start: int): string =
    entry.getToken({tokenEnd}, start)

template getTokenLen*(entry: string, tokenEnd: char, start: int): int =
    entry.getTokenLen({tokenEnd}, start)

proc tokens(entry: string, tokenEnd: char, start = 0): seq[string] =
    let entryLen = entry.len
    var i = start
    var tokensLen = 0
    
    # Iterate once to find out how many tokens there are in the string
    while i < entryLen:
        i += entry.getTokenLen(tokenEnd, i) + 1
        tokensLen += 1

    i = start
    result = newSeq[string](tokensLen)

    # Iterate again to build the result.
    for pos in countUp(0, tokensLen-1):
        result[pos] = entry.getToken(tokenEnd, i)

        i += result[pos].len + 1

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

proc lineProtocolToSQLEntryValues*(entry: string, result: var Table[ref string, SQLEntryValues], internedStrings: var Table[string, ref string]) {.gcsafe.} =
    let keyAndTags = entry.getToken(' ', 0)

    let fieldsStart = keyAndTags.len + 1
    let fields = entry.getToken(' ', fieldsStart)

    let timestamp = entry.getToken(' ', fieldsStart + fields.len + 1)

    var key = entry.getToken({',', ' '}, 0)

    let timeInterned = internedStrings["time"]

    let keyAndTagsList = keyAndTags.tokens(',', key.len + 1)
    let keyAndTagsListLen = keyAndTagsList.len
    let fieldsList = fields.tokens(',')
    let fieldsListLen = fieldsList.len

    var keyInterned = internedStrings.getOrDefault(key)
    if keyInterned == nil:
        shallow(key)

        new(keyInterned)
        keyInterned[].shallowCopy(key)

        internedStrings[key] = keyInterned

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
    entryValues[entryValuesPos] = newStringOfCap(timestamp.len + 14 + 29)
    entryValues[entryValuesPos].add("FROM_UNIXTIME(")
    entryValues[entryValuesPos].add(timestamp)
    entryValues[entryValuesPos].add("*0.000000001)")
    shallow(entryValues[entryValuesPos])

    for tagAndValue in keyAndTagsList.items:
        var tag = tagAndValue.getToken('=', 0)

        var tagInterned = internedStrings.getOrDefault(tag)
        if tagInterned == nil:
            shallow(tag)

            new(tagInterned)
            tagInterned[].shallowCopy(tag)

            internedStrings[tag] = tagInterned

        let entryValuesPos = order.mgetOrPut(tagInterned, order.len)

        entryValues.ensureSeqHasIndex(entryValuesLen, entryValuesPos)
        entryValues[entryValuesPos] = tagAndValue[tag.len+1..tagAndValue.len-1].escape("'", "'")
        shallow(entryValues[entryValuesPos])

    for nameAndValue in fieldsList.items:
        var name = nameAndValue.getToken('=', 0)
        var value = nameAndValue[name.len+1..nameAndValue.len-1]

        var nameInterned = internedStrings.getOrDefault(name)
        if nameInterned == nil:
            shallow(name)

            new(nameInterned)
            nameInterned[].shallowCopy(name)

            internedStrings[name] = nameInterned

        case value.valueType:
        of InfluxValueType.INTEGER:
            let entryValuesPos = order.mgetOrPut(nameInterned, order.len)

            entryValues.ensureSeqHasIndex(entryValuesLen, entryValuesPos)
            entryValues[entryValuesPos] = value[0..value.len-1]
            shallow(entryValues[entryValuesPos])
        of InfluxValueType.STRING:
            let entryValuesPos = order.mgetOrPut(nameInterned, order.len)

            entryValues.ensureSeqHasIndex(entryValuesLen, entryValuesPos)
            entryValues[entryValuesPos] = value.unescape.escape("'", "'")
            shallow(entryValues[entryValuesPos])
        of InfluxValueType.FLOAT:
            let entryValuesPos = order.mgetOrPut(nameInterned, order.len)

            shallow(value)
            entryValues.ensureSeqHasIndex(entryValuesLen, entryValuesPos)
            entryValues[entryValuesPos].shallowCopy(value)
            shallow(entryValues[entryValuesPos])
        of InfluxValueType.BOOLEAN_TRUE:
            let entryValuesPos = order.mgetOrPut(nameInterned, order.len)

            entryValues.ensureSeqHasIndex(entryValuesLen, entryValuesPos)
            entryValues[entryValuesPos].shallowCopy(booleanTrueValue)
            shallow(entryValues[entryValuesPos])
        of InfluxValueType.BOOLEAN_FALSE:
            let entryValuesPos = order.mgetOrPut(nameInterned, order.len)

            entryValues.ensureSeqHasIndex(entryValuesLen, entryValuesPos)
            entryValues[entryValuesPos].shallowCopy(booleanFalseValue)
            shallow(entryValues[entryValuesPos])


    result[keyInterned].entries.append(entryValues)

proc newSQLTableInsert(tableName: string): SQLTableInsert {.inline.} =
    result = (firstEntry: true, order: cast[OrderedTableRef[string, int] not nil](newOrderedTable[string, int]()),
        sql: cast[string not nil](newStringOfCap(SQL_BUFFER_SIZE)))

    result.order["time"] = result.order.len

    # Add header
    result.sql.add("INSERT INTO ")
    result.sql.add(tableName)
    result.sql.add(" (")

proc lineProtocolToSQLTableInsert*(entry: string, result: var Table[string, ref SQLTableInsert], entryValues: var seq[string]) {.gcsafe.} =
    var schemaLine = false

    let keyAndTags = entry.getToken(' ', 0)

    let fieldsStart = keyAndTags.len + 1
    let fields = entry.getToken(' ', fieldsStart)

    let timestamp = entry.getToken(' ', fieldsStart + fields.len + 1)

    var key = entry.getToken({',', ' '}, 0)

    let keyAndTagsList = keyAndTags.tokens(',', key.len + 1)
    let keyAndTagsListLen = keyAndTagsList.len
    let fieldsList = fields.tokens(',')
    let fieldsListLen = fieldsList.len

    if not result.hasKey(key):
        var newInsert: ref SQLTableInsert
        new(newInsert)
        newInsert[] = newSQLTableInsert(key)

        result[key] = newInsert
        schemaLine = true

    var insert = result[key]
    let order = insert.order

    # The length of the entry values seq is the total number of datapoints, if you will:
    # <number of tags> + <number of fields> + <one for the timestamp>
    var entryValuesLen = max(keyAndTagsListLen + fieldsListLen + 1, order.len)

    entryValues.setLen(0)
    entryValues.setLen(entryValuesLen)

    let entryValuesPos = order.mgetOrPut("time", order.len)

    entryValues.ensureSeqHasIndex(entryValuesLen, entryValuesPos)
    entryValues[entryValuesPos] = newStringOfCap(timestamp.len + 14 + 29)
    entryValues[entryValuesPos].add("FROM_UNIXTIME(")
    entryValues[entryValuesPos].add(timestamp)
    entryValues[entryValuesPos].add("*0.000000001)")

    for tagAndValue in keyAndTagsList.items:
        let tag = tagAndValue.getToken('=', 0)
        let entryValuesPos = order.mgetOrPut(tag, order.len)

        entryValues.ensureSeqHasIndex(entryValuesLen, entryValuesPos)
        entryValues[entryValuesPos] = tagAndValue[tag.len+1..tagAndValue.len-1].escape("'", "'")

    for nameAndValue in fieldsList.items:
        var name = nameAndValue.getToken('=', 0)
        var value = nameAndValue[name.len+1..nameAndValue.len-1]

        case value.valueType:
        of InfluxValueType.INTEGER:
            let entryValuesPos = order.mgetOrPut(name, order.len)

            entryValues.ensureSeqHasIndex(entryValuesLen, entryValuesPos)
            entryValues[entryValuesPos] = value[0..value.len-1]
        of InfluxValueType.STRING:
            let entryValuesPos = order.mgetOrPut(name, order.len)

            entryValues.ensureSeqHasIndex(entryValuesLen, entryValuesPos)
            entryValues[entryValuesPos] = value.unescape.escape("'", "'")
        of InfluxValueType.FLOAT:
            let entryValuesPos = order.mgetOrPut(name, order.len)

            entryValues.ensureSeqHasIndex(entryValuesLen, entryValuesPos)
            entryValues[entryValuesPos].shallowCopy(value)
        of InfluxValueType.BOOLEAN_TRUE:
            let entryValuesPos = order.mgetOrPut(name, order.len)

            entryValues.ensureSeqHasIndex(entryValuesLen, entryValuesPos)
            entryValues[entryValuesPos].shallowCopy(booleanTrueValue)
        of InfluxValueType.BOOLEAN_FALSE:
            let entryValuesPos = order.mgetOrPut(name, order.len)

            entryValues.ensureSeqHasIndex(entryValuesLen, entryValuesPos)
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

proc sqlEntryValuesToSQL*(kv: tuple[key: ref string, value: SQLEntryValues], result: var string) =
    # Add header
    result.add("INSERT INTO ")
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

    # Add SQL statement delimiter
    result.add(";\n")
