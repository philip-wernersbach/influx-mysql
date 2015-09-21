import unsigned
import strutils
import lists
import tables
import strtabs

#const QUERY_LANG_LEN = "INSERT INTO  (  ) VALUES (  );".len

type
    SQLEntryValues* = tuple
        order: OrderedTableRef[string, bool] not nil
        entries: ref DoublyLinkedList[StringTableRef] not nil

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

iterator tokens(entry: string, tokenEnd: char, start = 0): string =
    let entryLen = entry.len

    var i = start
    while i < entryLen:
        let token = entry.getToken(tokenEnd, i)
        yield token

        i += token.len + 1

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

proc lineProtocolToSQLEntryValues*(entry: string, result: var Table[string, SQLEntryValues]) =
    let keyAndTags = entry.getToken(' ', 0)

    let fieldsStart = keyAndTags.len + 1
    let fields = entry.getToken(' ', fieldsStart)

    let timestamp = entry.getToken(' ', fieldsStart + fields.len + 1)

    let key = entry.getToken({',', ' '}, 0)

    var timestampSQL = newStringOfCap(timestamp.len + 14 + 29)
    timestampSQL.add("FROM_UNIXTIME(")
    timestampSQL.add(timestamp)
    timestampSQL.add(" * 0.000000001)")

    if not result.hasKey(key):
        var entriesRef: ref DoublyLinkedList[StringTableRef]
        new(entriesRef)
        entriesRef[] = initDoublyLinkedList[StringTableRef]()

        result[key] = (order: cast[OrderedTableRef[string, bool] not nil](newOrderedTable[string, bool]()), 
                        entries: cast[ref DoublyLinkedList[StringTableRef] not nil](entriesRef))

    var entryValues = newStringTable(modeCaseSensitive)
    var order = result[key].order
    var entries = result[key].entries

    discard order.hasKeyOrPut("time", true)
    entryValues["time"] = timestampSQL

    for tagAndValue in keyAndTags.tokens(',', key.len + 1):
        let tag = tagAndValue.getToken('=', 0)
        let value = tagAndValue[tag.len+1..tagAndValue.len-1]

        discard order.hasKeyOrPut(tag, true)
        entryValues[tag] = value.escape("'", "'")

    for nameAndValue in fields.tokens(','):
        let name = nameAndValue.getToken('=', 0)
        let value = nameAndValue[name.len+1..nameAndValue.len-1]

        discard order.hasKeyOrPut(name, true)

        case value.valueType:
        of InfluxValueType.INTEGER:
            entryValues[name] = value[0..value.len-1]
        of InfluxValueType.STRING:
            entryValues[name] = value.unescape.escape("'", "'")
        of InfluxValueType.FLOAT:
            entryValues[name] = value
        of InfluxValueType.BOOLEAN_TRUE:
            entryValues[name] = "TRUE"
        of InfluxValueType.BOOLEAN_FALSE:
            entryValues[name] = "FALSE"

    entries[].append(entryValues)

proc sqlEntryValuesToSQL*(kv: tuple[key: string, value: SQLEntryValues], result: var string) =
    # Add header
    result.add("INSERT INTO ")
    result.add(kv.key)

    result.add(" ( ")

    var first = true
    for columnName in kv.value.order.keys:
        if not first:
            result.add(",")
        else:
            first = false

        result.add(columnName)

    # Add column values
    result.add(" ) VALUES")
    
    first = true
    for entry in kv.value.entries[].items:
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

            result.add(entry[columnName])

        result.add(" )")

    result.add(";\n")
