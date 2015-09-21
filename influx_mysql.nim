import macros
import unsigned
import strtabs
import strutils
import asynchttpserver
import asyncdispatch
import lists
import tables
import strtabs
import marshal
import json
import cgi
import qt5_qtsql

import qvariant
import qdatetime
import qsqlrecord
import influxql_to_sql
import influx_line_protocol_to_sql

type 
    DBQueryException = object of IOError
    URLParameterNotFoundError = object of ValueError

    JSONEntryValues = tuple
        order: OrderedTableRef[string, bool] not nil
        entries: ref DoublyLinkedList[TableRef[string, JSONField]] not nil

    SeriesAndData = tuple
        series: string
        data: JSONEntryValues

    # InfluxDB only supports four data types, which makes this easy
    # We add a fifth one so that we can properly support unsigned integers
    JSONFieldKind {.pure.} = enum
        Null,
        Integer,
        UInteger,
        Float,
        Boolean,
        String

    JSONField = object
        case kind: JSONFieldKind
        of JSONFieldKind.Null: discard
        of JSONFieldKind.Integer: intVal: int64
        of JSONFieldKind.UInteger: uintVal: uint64
        of JSONFieldKind.Float: floatVal: float64
        of JSONFieldKind.Boolean: booleanVal: bool
        of JSONFieldKind.String: stringVal: string

    QVariantType {.pure.} = enum
        Bool = 1
        Int = 2
        UInt = 3
        LongLong = 4
        ULongLong = 5
        Double = 6
        Char = 7
        String = 10
        Date = 14
        Time = 15
        DateTime = 16
        Long = 129
        Short = 130
        Char2 = 131
        ULong = 132
        UShort = 133
        UChar = 134
        Float = 135

    EpochFormat {.pure.} = enum
        RFC3339
        Hour
        Minute
        Second
        Millisecond
        Microsecond
        Nanosecond

macro useDB(body: stmt): stmt {.immediate.} =
    var safeBody = newNimNode(nnkTryStmt)
    safeBody.add(body)

    var safeBodyFinally = newNimNode(nnkFinally)
    safeBodyFinally.add(parseStmt("database.close"))
    
    safeBody.add(safeBodyFinally)

    result = newBlockStmt(newStmtList(parseStmt("""

var database = newQSqlDatabase("QMYSQL", "influx_mysql" & $cast[uint64](getGlobalDispatcher()))
database.setHostName("127.0.0.1")
database.setDatabaseName("influx")
database.setPort(3306)
database.open("test", "test")

    """), safeBody))

proc strdup(s: var string): string =
    result = newString(s.len)
    copyMem(addr(result[0]), addr(s[0]), result.len)

proc strdup(s: var cstring): string =
    result = newString(s.len)
    copyMem(addr(result[0]), addr(s[0]), result.len)

template useQuery(sql: cstring, query: var QSqlQueryObj) {.dirty.} =
    try:
        query.prepare(sql)
        query.exec
    except QSqlException:
        var exceptionMsg = cast[string](getCurrentExceptionMsg())
        var newExceptionMsg = exceptionMsg.strdup

        raise newException(DBQueryException, newExceptionMsg)

template useQuery(sql: cstring, database: var QSqlDatabaseObj) {.dirty.} =
    var query = database.qSqlQuery()
    sql.useQuery(query)

proc runDBQueryWithTransaction(sql: cstring) =
    useDB:
        database.beginTransaction
        sql.useQuery(database)
        database.commitTransaction

        # Workaround for weird compiler corner case
        database.close

proc getParams(request: Request): StringTableRef =
    result = newStringTable(modeCaseSensitive)

    for part in request.url.query.split('&'):
        let keyAndValue = part.split('=')

        if (keyAndValue.len == 2):
            result[keyAndValue[0]] = keyAndValue[1].decodeUrl

proc toRFC3339JSONField(dateTime: QDateTimeObj): JSONField =
    var timeStringConst = dateTime.toQStringObj("yyyy-MM-ddThh:mm:ss.zzz000000Z").toUtf8.constData.umc

    result.kind = JSONFieldKind.String
    result.stringVal = timeStringConst.strdup

proc toJSONField(msSinceEpoch: uint64, epoch: EpochFormat): JSONField =
    case epoch:
    of EpochFormat.RFC3339:
        result = newQDateTimeObj(qint64(msSinceEpoch)).toRFC3339JSONField
    of EpochFormat.Hour:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = msSinceEpoch div 3600000
    of EpochFormat.Minute:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = msSinceEpoch div 60000
    of EpochFormat.Second:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = msSinceEpoch div 1000
    of EpochFormat.Millisecond:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = msSinceEpoch
    of EpochFormat.Microsecond:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = msSinceEpoch * 1000
    of EpochFormat.Nanosecond:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = msSinceEpoch * 1000000

proc toJSONField(record: QSqlRecordObj, i: cint, epoch: EpochFormat): JSONField =
    if not record.isNull(i):
        var valueVariant = record.value(i)

        case QVariantType(valueVariant.userType):
        of QVariantType.Date, QVariantType.Time, QVariantType.DateTime:

            case epoch:
            of EpochFormat.RFC3339:
                result = valueVariant.toQDateTimeObj.toRFC3339JSONField
            else:
                result = uint64(valueVariant.toQDateTimeObj.toMSecsSinceEpoch).toJSONField(epoch)

        of QVariantType.Bool:

            result.kind = JSONFieldKind.Boolean
            result.booleanVal = valueVariant
        
        of QVariantType.Int, QVariantType.LongLong, QVariantType.Char, QVariantType.Long,
            QVariantType.Short, QVariantType.Char2: 

            result.kind = JSONFieldKind.Integer
            result.intVal = valueVariant

        of QVariantType.UInt, QVariantType.ULongLong, QVariantType.ULong,
            QVariantType.UShort, QVariantType.UChar:

            result.kind = JSONFieldKind.UInteger
            result.uintVal = valueVariant

        of QVariantType.Double, QVariantType.Float:

            result.kind = JSONFieldKind.Float
            result.floatVal = valueVariant

        of QVariantType.String:

            var valueStringConst = valueVariant.toQStringObj.toUtf8.constData.umc

            result.kind = JSONFieldKind.String
            result.stringVal = valueStringConst.strdup

        else:

            raise newException(ValueError, "Cannot unpack QVariantObj of type \"" & $valueVariant.userType & "\"!")
    else:
        result.kind = JSONFieldKind.Null

proc addNulls(entries: ref DoublyLinkedList[TableRef[string, JSONField]], order: OrderedTableRef[string, bool] not nil,
                lastTime: uint64, newTime: uint64, period: uint64, epoch: EpochFormat) =

    var lastTime = lastTime

    if ((newTime - lastTime) div period) > uint64(1):
        while true:
            lastTime += period

            if lastTime >= newTime:
                break

            var entryValues = newTable[string, JSONField]()
            for fieldName in order.keys:
                if fieldName != "time":
                    entryValues[fieldName] = JSONField(kind: JSONFieldKind.Null)
                else:
                    entryValues["time"] = lastTime.toJSONField(epoch)

            entries[].append(entryValues)

proc runDBQueryAndUnpack(sql: cstring, series: string, period: uint64, epoch: EpochFormat, result: var DoublyLinkedList[SeriesAndData])  =
    useDB:
        sql.useQuery(database)

        var entries: ref DoublyLinkedList[TableRef[string, JSONField]]
        new(entries)
        entries[] = initDoublyLinkedList[TableRef[string, JSONField]]()

        var seriesAndData = (series: series, data: (order: cast[OrderedTableRef[string, bool] not nil](newOrderedTable[string, bool]()), 
                                entries: cast[ref DoublyLinkedList[TableRef[string, JSONField]] not nil](entries)))
        result.append(seriesAndData)

        var order = seriesAndData.data.order

        var lastTime = uint64(0)
        var first = true

        while query.next() == true:
            var record = query.record
            let count = record.count - 1

            var entryValues = newTable[string, JSONField]()

            # For strict InfluxDB compatibility:
            #
            # InfluxDB will automatically return NULLs if there is no data for that GROUP BY timeframe block.
            # SQL databases do not do this, they return nothing if there is no data. So we need to add these
            # NULLs.
            var newTime = uint64(record.value("time").toMSecsSinceEpoch)

            if (period > uint64(0)) and not first:
                entries.addNulls(order, lastTime, newTime, period, epoch)
            else:
                first = false

            lastTime = newTime

            for i in countUp(0, count):
                var fieldNameConst = record.fieldName(i).toUtf8.constData.umc
                var fieldName: string = fieldNameConst.strdup

                # For strict InfluxDB compatibilty:
                #
                # We only return the name of the functions as the field, and not the name and the arguments.
                #
                # We also change "AVG" to "mean" since we change "mean" to "AVG" in the InfluxQL to SQL conversion.
                if fieldName[fieldName.len-1] == ')':
                    fieldName = fieldName.getToken('(', 0)

                    if fieldName == "AVG":
                        fieldName = "mean"

                var value = record.toJSONField(i, epoch)

                discard order.hasKeyOrPut(fieldName, true)
                entryValues[fieldName] = value

            entries[].append(entryValues)

converter toJsonNode(field: JSONField): JsonNode =
    case field.kind:
    of JSONFieldKind.Null: result = newJNull()
    of JSONFieldKind.Integer: result = newJInt(BiggestInt(field.intVal))
    of JSONFieldKind.UInteger: result = newJInt(BiggestInt(field.uintVal))
    of JSONFieldKind.Float: result = newJFloat(field.floatVal)
    of JSONFieldKind.Boolean: result = newJBool(field.booleanVal)
    of JSONFieldKind.String: result = newJString(field.stringVal)

proc toJsonNode(kv: SeriesAndData): JsonNode =
    result = newJObject()
    var seriesArray = newJArray()
    var seriesObject = newJObject()

    seriesObject.add("name", newJString(kv.series))

    var columns = newJArray()

    for column in kv.data.order.keys:
        columns.add(newJString(column))

    seriesObject.add("columns", columns)

    var valuesArray = newJArray()

    for entry in kv.data.entries[].items:
        var entryArray = newJArray()

        for column in kv.data.order.keys:
            entryArray.add(entry[column])

        valuesArray.add(entryArray)

    seriesObject.add("values", valuesArray)

    seriesArray.add(seriesObject)
    result.add("series", seriesArray)

proc toQueryResponse(ev: DoublyLinkedList[SeriesAndData]): string =
    var json = newJObject()
    var results = newJArray()

    for keyAndValue in ev.items:
        results.add(keyAndValue.toJsonNode)

    json.add("results", results)
    result = $json

proc getQuery(request: Request) {.async.} =
    let params = getParams(request)

    let urlQuery = params["q"]
    let specifiedEpochFormat = params["epoch"]

    var epoch = EpochFormat.RFC3339

    if specifiedEpochFormat != nil:
        case specifiedEpochFormat:
        of "h": epoch = EpochFormat.Hour
        of "m": epoch = EpochFormat.Minute
        of "s": epoch = EpochFormat.Second
        of "ms": epoch = EpochFormat.Millisecond
        of "u": epoch = EpochFormat.Microsecond
        of "ns": epoch = EpochFormat.Nanosecond

    if urlQuery == nil:
        raise newException(URLParameterNotFoundError, "No \"q\" query parameter specified!")

    var entries = initDoublyLinkedList[tuple[series: string, data: JSONEntryValues]]()

    for line in urlQuery.splitLines:
        var series: string
        var period = uint64(0)

        let sql = line.influxQlToSql(series, period)
        
        when defined(logrequests):
            stdout.write("/query: ")
            stdout.write(line)
            stdout.write(" --> ")
            stdout.writeln(sql)

        sql.runDBQueryAndUnpack(series, period, epoch, entries)

    result = request.respond(Http200, entries.toQueryResponse, newStringTable("Content-Type", "application/json", modeCaseSensitive))

proc postWrite(request: Request) {.async.} =
    var entries = initTable[string, SQLEntryValues]()
    var sql = newStringOfCap(2097152)

    for line in request.body.splitLines:
        if line.len > 0:
            line.lineProtocolToSQLEntryValues(entries)

            when defined(logrequests):
                stdout.write("/write: ")
                stdout.writeln(line)

    for pair in entries.pairs:
        pair.sqlEntryValuesToSQL(sql)

        when defined(logrequests):
            stdout.write("/write: ")
            stdout.writeln(sql)

        sql.runDBQueryWithTransaction
        sql.setLen(0)

    result = request.respond(Http204, "", newStringTable(modeCaseSensitive))

proc router(request: Request) {.async.} =
    when defined(logrequests):
        stdout.write(request.url.path)
        stdout.write('?')
        stdout.writeln(request.url.query)

    try:
        if (request.reqMethod == "get") and (request.url.path == "/query"):
            asyncCheck request.getQuery
        elif (request.reqMethod == "post") and (request.url.path == "/write"):
            asyncCheck request.postWrite
        else:
            let responseMessage = "Route not found for [reqMethod=" & request.reqMethod & ", url=" & request.url.path & "]"
            stdout.writeln(responseMessage)

            asyncCheck request.respond(Http400, responseMessage, newStringTable(modeCaseSensitive))
    except DBQueryException, URLParameterNotFoundError:
        let e = getCurrentException()
        stderr.write(e.getStackTrace())
        stderr.write("Error: unhandled exception: ")
        stderr.writeln(getCurrentExceptionMsg())

        result = request.respond(Http400, $( %*{ "error": getCurrentExceptionMsg() } ), newStringTable("Content-Type", "application/json", modeCaseSensitive))

block:
    try:
        waitFor newAsyncHttpServer().serve(Port(8086), router)
    except Exception:
        let e = getCurrentException()
        stderr.write(e.getStackTrace())
        stderr.write("Error: unhandled exception: ")
        stderr.writeln(getCurrentExceptionMsg())
