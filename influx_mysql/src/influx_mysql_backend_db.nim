# influx_mysql_backend_db.nim
# Part of influx-mysql by Philip Wernersbach <philip.wernersbach@gmail.com>
#
# Copyright (c) 2017, Philip Wernersbach
#
# The source code in this file is licensed under the 2-Clause BSD License.
# See the LICENSE file in this project's root directory for the license
# text.

when compileOption("threads"):
    import locks

import tables

import qt5_qtsql

import stdlib_extra
import influx_line_protocol_to_sql
import influx_mysql_backend

type
    DBQueryException* = object of IOError

when not compileOption("threads"):
    proc initBackendDB*(dbHostname: string, dbPort: int) =
        var database = newQSqlDatabase("QMYSQL", "influx_mysql")

        database.setHostName(dbHostName)
        database.setPort(cint(dbPort))
else:
    var dbHostname: cstring = nil
    var dbPort: cint = 0

    var qSqlDatabaseThreadConnectionName {.threadvar.}: string
    var qSqlDatabaseAddRemoveLock: Lock

    proc initBackendDB*(hostname: var string, port: int) =
        qSqlDatabaseAddRemoveLock.initLock

        dbHostname = cast[cstring](allocShared0(hostname.len + 1))
        copyMem(addr(dbHostname[0]), addr(hostname[0]), hostname.len)

        dbPort = cint(port)

    proc initBackendDBForThread*(threadConnectionName: string) =
        # The QT documentation guarantees that adding and removing database connections
        # is thread-safe. However, the QMYSQL driver uses reference counting to count
        # how many connections are active. This reference counting is not thread safe, so
        # therefore we must ensure that only one thread at a time creates and removes
        # database connections.

        # This variable is required because if an exception occurs in a critical section,
        # we need to know if releasing the lock in the exception handler is required.
        #
        # We can't do this with a try-finally block because a try-finally block creates a
        # new scope, and the database connection must stay in scope while it is used.
        var lockAcquired = false

        try:
            qSqlDatabaseAddRemoveLock.acquire
            lockAcquired = true

            var database = newQSqlDatabase("QMYSQL", threadConnectionName)
            
            qSqlDatabaseAddRemoveLock.release
            lockAcquired = false

            database.setHostName(dbHostName)
            database.setPort(dbPort)

            qSqlDatabaseThreadConnectionName = threadConnectionName
        except Exception:
            if lockAcquired:
                qSqlDatabaseAddRemoveLock.release

template useDB*(dbName: untyped, dbUsername: untyped, dbPassword: untyped, body: untyped) {.dirty.} =

    var database = when not compileOption("threads"):
            getQSqlDatabase("influx_mysql", false)
        else:
            getQSqlDatabase(qSqlDatabaseThreadConnectionName, false)

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
            stdout.write("/write: ")
            stdout.writeLine(sql)

        sql.runDBQueryWithTransaction(dbName, dbUsername, dbPassword)

proc processSQLTableInsertsAndRunDBQuery*(inserts: var Table[string, ref SQLTableInsert], dbName: cstring, dbUsername: cstring, dbPassword: cstring) {.inline.} =
    inserts.processSQLTableInserts:
        when defined(logrequests):
            stdout.write("/write: ")
            stdout.writeLine(insert.sql)

        insert.sql.runDBQueryWithTransaction(dbName, dbUsername, dbPassword)
