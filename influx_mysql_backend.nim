import macros
import strutils
import tables

import qt5_qtsql

import stdlib_extra
import reflists
import qsqldatabase
import influx_line_protocol_to_sql

type
    DBQueryException* = object of IOError

    ReadLinesContextSchemaless = ref tuple
        internedStrings: Table[string, ref string]
        entries: Table[ref string, SQLEntryValues]

    ReadLinesContextSchemaful = ref tuple
        entryValues: seq[string]
        inserts: Table[string, ref SQLTableInsert]

    ReadLinesContext* = tuple
        compressed: bool
        destroyed: bool
        line: string
        lines: string
        schemaless: ReadLinesContextSchemaless
        schemaful: ReadLinesContextSchemaful
        bop: LineProtocolBufferObjectPool

var dbHostname*: cstring = nil
var dbPort*: cint = 0

macro useDB*(dbName: string, dbUsername: string, dbPassword: string, body: stmt): stmt {.immediate.} =
    # Create the try block that closes the database.
    var safeBodyClose = newNimNode(nnkTryStmt)
    safeBodyClose.add(body)

    ## Create the finally clause
    var safeBodyCloseFinally = newNimNode(nnkFinally)
    safeBodyCloseFinally.add(parseStmt("database.close"))
    
    ## Add the finally clause to the try block.
    safeBodyClose.add(safeBodyCloseFinally)

    # Create the try block that removes the database.
    var safeBodyRemove = newNimNode(nnkTryStmt)
    safeBodyRemove.add(
        newBlockStmt(
            newStmtList(
                newVarStmt(newIdentNode(!"database"), newCall(!"newQSqlDatabase", newStrLitNode("QMYSQL"), newIdentNode(!"qSqlDatabaseName"))),
                newCall(!"setHostName", newIdentNode(!"database"), newIdentNode(!"dbHostName")),
                newCall(!"setDatabaseName", newIdentNode(!"database"), dbName),
                newCall(!"setPort", newIdentNode(!"database"), newIdentNode(!"dbPort")),
                newCall(!"open", newIdentNode(!"database"), dbUsername, dbPassword),
                safeBodyClose
            )
        )
    )

    ## Create the finally clause.
    var safeBodyRemoveFinally = newNimNode(nnkFinally)
    safeBodyRemoveFinally.add(parseStmt("qSqlDatabaseRemoveDatabase(qSqlDatabaseName)"))

    ## Add the finally clause to the try block.
    safeBodyRemove.add(safeBodyRemoveFinally)

    # Put it all together.
    result = newBlockStmt(
                newStmtList(
                    parseStmt("""

var qSqlDatabaseStackId: uint8
var qSqlDatabaseName = "influx_mysql" & $cast[uint64](addr(qSqlDatabaseStackId))
                    """), 
                    safeBodyRemove
                )
            )

template useQuery*(sql: cstring, query: var QSqlQueryObj) {.dirty.} =
    try:
        query.prepare(sql)
        query.exec
    except QSqlException:
        var exceptionMsg = cast[string](getCurrentExceptionMsg())
        var newExceptionMsg = exceptionMsg.strdup

        raise newException(DBQueryException, newExceptionMsg)

template useQuery*(sql: cstring, database: var QSqlDatabaseObj) {.dirty.} =
    var query = database.qSqlQuery()
    sql.useQuery(query)

proc runDBQueryWithTransaction*(sql: cstring, dbName: cstring, dbUsername: cstring, dbPassword: cstring) =
    useDB(dbName, dbUsername, dbPassword):
        block:
            "SET time_zone='UTC'".useQuery(database)

        database.beginTransaction
        sql.useQuery(database)
        database.commitTransaction

        # Workaround for weird compiler corner case
        database.close

proc linesToSQLEntryValues*(context: var ReadLinesContext) {.inline.} =
    var lineStart = 0

    while lineStart < context.lines.len:
        let lineEnd = context.lines.find("\n", lineStart) - "\n".len

        if lineEnd < 0 or lineEnd >= context.lines.len:
            break

        let lineNewSize = lineEnd - lineStart + 1
        context.line.setLen(lineNewSize)
        copyMem(addr(context.line[0]), addr(context.lines[lineStart]), lineNewSize)

        if context.line.len > 0:
            when defined(logrequests):
                stdout.write("/write: ")
                stdout.writeLine(context.line)

            if context.schemaful != nil:
                context.line.lineProtocolToSQLTableInsert(context.schemaful.inserts, context.schemaful.entryValues, context.bop)
            else:
                context.line.lineProtocolToSQLEntryValues(context.schemaless.entries, context.schemaless.internedStrings, context.bop)

        lineStart = lineEnd + "\n".len + 1

    if lineStart < context.lines.len:
        let linesNewSize = context.lines.len - lineStart
        
        moveMem(addr(context.lines[0]), addr(context.lines[lineStart]), linesNewSize)
        context.lines.setLen(linesNewSize)
    else:
        context.lines.setLen(0)

proc processSQLEntryValuesAndRunDBQuery*(entries: var Table[ref string, SQLEntryValues], dbName: cstring, dbUsername: cstring, dbPassword: cstring) {.inline.} =
    var sql = newStringOfCap(SQL_BUFFER_SIZE)

    for pair in entries.pairs:
        pair.sqlEntryValuesToSQL(sql)

        when defined(logrequests):
            stdout.write("/write: ")
            stdout.writeLine(sql)

        sql.runDBQueryWithTransaction(dbName, dbUsername, dbPassword)
        sql.setLen(0)

proc processSQLTableInsertsAndRunDBQuery*(inserts: var Table[string, ref SQLTableInsert], dbName: cstring, dbUsername: cstring, dbPassword: cstring) {.inline.} =
    # Iterating over the keys is a workaround, Nim generates the wrong code in C++ mode for
    # tables.mvalues
    for insertKey in inserts.keys:
        var insert = inserts[insertKey]

        # Add SQL statement delimiter
        insert.sql.add(";\n")

        when defined(logrequests):
            stdout.write("/write: ")
            stdout.writeLine(insert.sql)

        insert.sql.runDBQueryWithTransaction(dbName, dbUsername, dbPassword)

proc newReadLinesContext*(compressed: bool, schemaful: bool, lines: string): ReadLinesContext {.inline.} =
    if schemaful:
        var schemafulContext: ReadLinesContextSchemaful
        new(schemafulContext)
        schemafulContext[] = (entryValues: newSeq[string](), inserts: initTable[string, ref SQLTableInsert]())

        result = (compressed: compressed, destroyed: false, line: "", lines: lines, schemaless: ReadLinesContextSchemaless(nil), schemaful: schemafulContext,
            bop: (freeBstring: 2, bstring: newSeq[string](3), keyAndTagsList: newSeq[int](), fieldsList: newSeq[int]()))

        result.bop.bstring[0] = newStringOfCap(64)
        result.bop.bstring[1] = newStringOfCap(64)
        result.bop.bstring[2] = newStringOfCap(64)
    else:
        var schemalessContext: ReadLinesContextSchemaless

        var timeInterned: ref string
        new(timeInterned)
        timeInterned[] = "time"

        var internedStrings = initTable[string, ref string]()
        internedStrings["time"] = timeInterned

        new(schemalessContext)
        schemalessContext[] = (internedStrings: internedStrings, entries: initTable[ref string, SQLEntryValues]())

        result = (compressed: compressed, destroyed: false, line: "", lines: lines, schemaless: schemalessContext, schemaful: ReadLinesContextSchemaful(nil),
            bop: (freeBstring: 1, bstring: newSeq[string](2), keyAndTagsList: newSeq[int](), fieldsList: newSeq[int]()))

        result.bop.bstring[0] = newStringOfCap(64)
        result.bop.bstring[1] = newStringOfCap(64)

proc destroyReadLinesContext*(context: var ReadLinesContext) {.inline.} =
    if not context.destroyed:
        # SQLEntryValues.entries is a manually allocated object, so we
        # need to free it.
        if context.schemaless != nil:
            for entry in context.schemaless.entries.values:
                entry.entries.removeAll

        context.destroyed = true

template uncompressOverwrite*(context: var ReadLinesContext) =
    if context.compressed:
        context.lines = snappy.uncompress(context.lines)
        context.compressed = false
