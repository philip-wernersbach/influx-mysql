import strutils
import hashes as hashes
import tables
import strtabs

import reflists

#const QUERY_LANG_LEN = "INSERT INTO  (  ) VALUES (  );".len

type
    SQLEntryValues* = tuple
        order: OrderedTableRef[ref string, int] not nil
        entries: SinglyLinkedRefList[seq[string]] not nil

template hash(x: ref string): Hash =
    hashes.hash(cast[pointer](x))

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

proc lineProtocolToSQLEntryValues*(entry: string, result: var Table[ref string, SQLEntryValues], internedStrings: var Table[string, ref string]) =
    let keyAndTags = entry.getToken(' ', 0)

    let fieldsStart = keyAndTags.len + 1
    let fields = entry.getToken(' ', fieldsStart)

    let timestamp = entry.getToken(' ', fieldsStart + fields.len + 1)

    let key = entry.getToken({',', ' '}, 0)

    let timeInterned = internedStrings["time"]

    let keyAndTagsList = keyAndTags.tokens(',', key.len + 1)
    let keyAndTagsListLen = keyAndTagsList.len
    let fieldsList = fields.tokens(',')
    let fieldsListLen = fieldsList.len

    var timestampSQL = newStringOfCap(timestamp.len + 14 + 29)
    timestampSQL.add("FROM_UNIXTIME(")
    timestampSQL.add(timestamp)
    timestampSQL.add(" * 0.000000001)")

    var keyInterned = internedStrings.getOrDefault(key)
    if keyInterned == nil:
        new(keyInterned)
        keyInterned[] = key

        internedStrings[key] = keyInterned

    if not result.hasKey(keyInterned):
        result[keyInterned] = (order: cast[OrderedTableRef[ref string, int] not nil](newOrderedTable[ref string, int]()), 
                        entries: newSinglyLinkedRefList[seq[string]]())

    let order = result[keyInterned].order

    # The length of the entry values seq is the total number of datapoints, if you will:
    # <number of tags> + <number of fields> + <one for the timestamp>
    let entryValuesLen = keyAndTagsListLen + fieldsListLen + 1

    var entryValues: ref seq[string]
    new(entryValues)
    entryValues[] = newSeq[string](entryValuesLen)

    shallow(timestampSQL)
    entryValues[order.mgetOrPut(timeInterned, order.len)].shallowCopy(timestampSQL)

    for tagAndValue in keyAndTagsList.items:
        let tag = tagAndValue.getToken('=', 0)
        var value = tagAndValue[tag.len+1..tagAndValue.len-1]

        var tagInterned = internedStrings.getOrDefault(tag)
        if tagInterned == nil:
            new(tagInterned)
            tagInterned[] = tag

            internedStrings[tag] = tagInterned

        value = value.escape("'", "'")
        shallow(value)
        entryValues[order.mgetOrPut(tagInterned, order.len)].shallowCopy(value)

    for nameAndValue in fieldsList.items:
        let name = nameAndValue.getToken('=', 0)
        var value = nameAndValue[name.len+1..nameAndValue.len-1]

        var nameInterned = internedStrings.getOrDefault(name)
        if nameInterned == nil:
            new(nameInterned)
            nameInterned[] = name

            internedStrings[name] = nameInterned

        case value.valueType:
        of InfluxValueType.INTEGER:
            value = value[0..value.len-1]
            shallow(value)

            entryValues[order.mgetOrPut(nameInterned, order.len)].shallowCopy(value)
        of InfluxValueType.STRING:
            value = value.unescape.escape("'", "'")
            shallow(value)

            entryValues[order.mgetOrPut(nameInterned, order.len)].shallowCopy(value)
        of InfluxValueType.FLOAT:
            shallow(value)

            entryValues[order.mgetOrPut(nameInterned, order.len)].shallowCopy(value)
        of InfluxValueType.BOOLEAN_TRUE:
            value = "TRUE"
            shallow(value)

            entryValues[order.mgetOrPut(nameInterned, order.len)].shallowCopy(value)
        of InfluxValueType.BOOLEAN_FALSE:
            value = "FALSE"
            shallow(value)
            
            entryValues[order.mgetOrPut(nameInterned, order.len)].shallowCopy(value)

    result[keyInterned].entries.append(entryValues)

proc sqlEntryValuesToSQL*(kv: tuple[key: ref string, value: SQLEntryValues], result: var string) =
    # Add header
    result.add("INSERT INTO ")
    result.add(kv.key[])

    result.add(" ( ")

    var first = true
    for columnName in kv.value.order.keys:
        if not first:
            result.add(",")
        else:
            first = false

        result.add(columnName[])

    # Add column values
    result.add(" ) VALUES")
    
    first = true
    for entry in kv.value.entries.items:
        if not first:
            result.add(",")
        else:
            first = false

        result.add(" ( ")
        
        for columnPos in kv.value.order.values:
            if columnPos > 0:
                result.add(",")

            if entry[columnPos] != nil:
                result.add(entry[columnPos])
            else:
                result.add("NULL")

        result.add(" )")

    result.add(";\n")
