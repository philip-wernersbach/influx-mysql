import strutils
import hashes as hashes
import tables
import strtabs
import lists

import reflists

#const QUERY_LANG_LEN = "INSERT INTO  (  ) VALUES (  );".len

type
    SQLEntryValues* = tuple
        order: OrderedTableRef[ref string, bool] not nil
        entries: SinglyLinkedRefList[Table[ref string, string]] not nil

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

template getToken*(entry: string, tokenEnd: char, start: int): string =
    entry.getToken({tokenEnd}, start)

proc tokens(entry: string, tokensLen: var int, tokenEnd: char, start = 0): DoublyLinkedList[string] =
    let entryLen = entry.len
    var i = start

    result = initDoublyLinkedList[string]()

    tokensLen = 0
    while i < entryLen:
        let token = entry.getToken(tokenEnd, i)
        result.append(token)

        i += token.len + 1
        tokensLen += 1

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

    var keyAndTagsListLen: int
    var fieldsListLen: int
    let keyAndTagsList = keyAndTags.tokens(keyAndTagsListLen, ',', key.len + 1)
    let fieldsList = fields.tokens(fieldsListLen, ',')

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
        result[keyInterned] = (order: cast[OrderedTableRef[ref string, bool] not nil](newOrderedTable[ref string, bool]()), 
                        entries: newSinglyLinkedRefList[Table[ref string, string]]())

    var entryValues = newTable[ref string, string]((keyAndTagsListLen + fieldsListLen).rightSize)
    var order = result[keyInterned].order
    var entries = result[keyInterned].entries

    discard order.hasKeyOrPut(timeInterned, true)
    shallow(timestampSQL)
    entryValues[timeInterned] = timestampSQL

    for tagAndValue in keyAndTagsList.items:
        let tag = tagAndValue.getToken('=', 0)
        var value = tagAndValue[tag.len+1..tagAndValue.len-1]

        var tagInterned = internedStrings.getOrDefault(tag)
        if tagInterned == nil:
            new(tagInterned)
            tagInterned[] = tag

            internedStrings[tag] = tagInterned

        discard order.hasKeyOrPut(tagInterned, true)

        value = value.escape("'", "'")
        shallow(value)
        entryValues[tagInterned] = value

    for nameAndValue in fieldsList.items:
        let name = nameAndValue.getToken('=', 0)
        var value = nameAndValue[name.len+1..nameAndValue.len-1]

        var nameInterned = internedStrings.getOrDefault(name)
        if nameInterned == nil:
            new(nameInterned)
            nameInterned[] = name

            internedStrings[name] = nameInterned

        discard order.hasKeyOrPut(nameInterned, true)

        case value.valueType:
        of InfluxValueType.INTEGER:
            value = value[0..value.len-1]
            shallow(value)

            entryValues[nameInterned] = value
        of InfluxValueType.STRING:
            value = value.unescape.escape("'", "'")
            shallow(value)

            entryValues[nameInterned] = value
        of InfluxValueType.FLOAT:
            shallow(value)

            entryValues[nameInterned] = value
        of InfluxValueType.BOOLEAN_TRUE:
            value = "TRUE"
            shallow(value)

            entryValues[nameInterned] = value
        of InfluxValueType.BOOLEAN_FALSE:
            value = "FALSE"
            shallow(value)
            
            entryValues[nameInterned] = value

    entries.append(entryValues)

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
        
        var first2 = true
        for columnName in kv.value.order.keys:
            if not first2:
                result.add(",")
            else:
                first2 = false

            if entry.hasKey(columnName):
                result.add(entry[columnName])
            else:
                result.add("NULL")

        result.add(" )")

    result.add(";\n")
