# influx_mysql_backend_db.nim
# Part of influx-mysql by Philip Wernersbach <philip.wernersbach@gmail.com>
#
# Copyright (c) 2017, Philip Wernersbach
#
# The source code in this file is licensed under the 2-Clause BSD License.
# See the LICENSE file in this project's root directory for the license
# text.

import os
import tables

import qt5_qtsql

import stdlib_extra
import influx_line_protocol_to_sql
import influx_mysql_backend

type
    DBException* = object of IOError

when getEnv("maxdbconnections") != "":
    from strutils import parseInt

    const MAX_DB_CONNECTIONS* = getEnv("maxdbconnections").parseInt
else:
    const MAX_DB_CONNECTIONS* = 2048

proc initBackendDB*(dbHostname: string, dbPort: int) =
    for i in countUp(0, MAX_DB_CONNECTIONS - 1):
        var database = newQSqlDatabase("QMYSQL", "influx_mysql" & $i)

        database.setHostName(dbHostName)
        database.setPort(cint(dbPort))

proc unInitBackendDB*() =
    for i in countUp(0, MAX_DB_CONNECTIONS - 1):
        qSqlDatabaseRemoveDatabase("influx_mysql" & $i)

template useDB*(connectionId: int, dbName: untyped, dbUsername: untyped, dbPassword: untyped, body: untyped) {.dirty.} =
    try:
        var database = getQSqlDatabase("influx_mysql" & $connectionId, false)

        database.setDatabaseName(dbName)
        database.open(dbUsername, dbPassword)

        try:
            body
        finally:
            database.close
    except QSqlException:
        var exceptionMsg = cast[string](getCurrentExceptionMsg())
        var newExceptionMsg = exceptionMsg.strdup

        raise newException(DBException, newExceptionMsg)

template useQuery*(sql: cstring, query: var QSqlQueryObj) {.dirty.} =
    query.prepare(sql)
    query.exec

template useQuery*(sql: cstring, database: var QSqlDatabaseObj) {.dirty.} =
    var query = database.qSqlQuery()
    sql.useQuery(query)

proc runDBQueryWithTransaction*(sql: cstring, connectionId: int, dbName: cstring, dbUsername: cstring, dbPassword: cstring) =
    useDB(connectionId, dbName, dbUsername, dbPassword):
        block:
            "SET time_zone='+0:00'".useQuery(database)

        database.beginTransaction
        sql.useQuery(database)
        database.commitTransaction

        # Workaround for weird compiler corner case
        database.close

proc processSQLEntryValuesAndRunDBQuery*(entries: var Table[ref string, SQLEntryValues], insertType: SQLInsertType, connectionId: int, dbName: cstring, dbUsername: cstring, dbPassword: cstring) {.inline.} =
    entries.processSQLEntryValues(insertType):
        when defined(logrequests):
            stdout.write("Debug: ")
            stdout.write("/write: ")
            stdout.writeLine(sql)

        sql.runDBQueryWithTransaction(connectionId, dbName, dbUsername, dbPassword)

proc processSQLTableInsertsAndRunDBQuery*(inserts: var Table[string, ref SQLTableInsert], connectionId: int, dbName: cstring, dbUsername: cstring, dbPassword: cstring) {.inline.} =
    inserts.processSQLTableInserts:
        when defined(logrequests):
            stdout.write("Debug: ")
            stdout.write("/write: ")
            stdout.writeLine(insert.sql)

        insert.sql.runDBQueryWithTransaction(connectionId, dbName, dbUsername, dbPassword)
