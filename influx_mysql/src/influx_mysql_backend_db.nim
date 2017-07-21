# influx_mysql_backend_db.nim
# Part of influx-mysql by Philip Wernersbach <philip.wernersbach@gmail.com>
#
# Copyright (c) 2017, Philip Wernersbach
#
# The source code in this file is licensed under the 2-Clause BSD License.
# See the LICENSE file in this project's root directory for the license
# text.

import tables

import qt5_qtsql

import stdlib_extra
import influx_line_protocol_to_sql
import influx_mysql_backend

type
    DBQueryException* = object of IOError

proc initBackendDB*(dbHostname: string, dbPort: int) =
    var database = newQSqlDatabase("QMYSQL", "influx_mysql")

    database.setHostName(dbHostName)
    database.setPort(cint(dbPort))

template useDB*(dbName: untyped, dbUsername: untyped, dbPassword: untyped, body: untyped) {.dirty.} =
    var database = getQSqlDatabase("influx_mysql", false)

    database.setDatabaseName(dbName)
    database.open(dbUsername, dbPassword)

    try:
        body
    finally:
        database.close

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
            "SET time_zone='+0:00'".useQuery(database)

        database.beginTransaction
        sql.useQuery(database)
        database.commitTransaction

        # Workaround for weird compiler corner case
        database.close

proc processSQLEntryValuesAndRunDBQuery*(entries: var Table[ref string, SQLEntryValues], insertType: SQLInsertType, dbName: cstring, dbUsername: cstring, dbPassword: cstring) {.inline.} =
    entries.processSQLEntryValues(insertType):
        when defined(logrequests):
            stdout.write("Debug: ")
            stdout.write("/write: ")
            stdout.writeLine(sql)

        sql.runDBQueryWithTransaction(dbName, dbUsername, dbPassword)

proc processSQLTableInsertsAndRunDBQuery*(inserts: var Table[string, ref SQLTableInsert], dbName: cstring, dbUsername: cstring, dbPassword: cstring) {.inline.} =
    inserts.processSQLTableInserts:
        when defined(logrequests):
            stdout.write("Debug: ")
            stdout.write("/write: ")
            stdout.writeLine(insert.sql)

        insert.sql.runDBQueryWithTransaction(dbName, dbUsername, dbPassword)
