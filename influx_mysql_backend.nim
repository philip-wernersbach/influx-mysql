import macros
import strutils
import tables
import os

import qt5_qtsql

import stdlib_extra
import qsqldatabase
import influx_line_protocol_to_sql

type
    DBQueryException* = object of IOError
    ReadLinesContext* = tuple
        compressed: bool
        destroyed: bool
        line: string
        lines: string
        internedStrings: Table[string, ref string]
        entries: Table[ref string, SQLEntryValues]

var dbHostname*: cstring = nil
var dbPort*: cint = 0

# sqlbuffersize sets the initial size of the SQL INSERT query buffer for POST /write commands.
# The default size is MySQL's default max_allowed_packet value. Setting this to a higher size
# will improve memory usage for INSERTs larger than the size, at the expense of overallocating
# memory for INSERTs smaller than the size.
when getEnv("sqlbuffersize") == "":
    const SQL_BUFFER_SIZE = 2097152
else:
    const SQL_BUFFER_SIZE = getEnv("sqlbuffersize").parseInt

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

proc runDBQueryWithTransaction(sql: cstring, dbName: string, dbUsername: string, dbPassword: string) =
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

            context.line.lineProtocolToSQLEntryValues(context.entries, context.internedStrings)

        lineStart = lineEnd + "\n".len + 1

    if lineStart < context.lines.len:
        let linesNewSize = context.lines.len - lineStart
        
        moveMem(addr(context.lines[0]), addr(context.lines[lineStart]), linesNewSize)
        context.lines.setLen(linesNewSize)
    else:
        context.lines.setLen(0)

proc processSQLEntryValuesAndRunDBQuery*(context: var ReadLinesContext, dbName: string, dbUsername: string, dbPassword: string) {.inline.} =
    var sql = newStringOfCap(SQL_BUFFER_SIZE)

    for pair in context.entries.pairs:
        pair.sqlEntryValuesToSQL(sql)

        when defined(logrequests):
            stdout.write("/write: ")
            stdout.writeLine(sql)

        sql.runDBQueryWithTransaction(dbName, dbUsername, dbPassword)
        sql.setLen(0)

template uncompressOverwrite*(context: var ReadLinesContext) =
    if context.compressed:
        context.lines = snappy.uncompress(context.lines)
        context.compressed = false
