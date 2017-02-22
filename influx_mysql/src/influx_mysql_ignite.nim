# influx_mysql_ignite.nim
# Part of influx-mysql by Philip Wernersbach <philip.wernersbach@gmail.com>
#
# Copyright (c) 2016-2017, Philip Wernersbach
#
# The source code in this file is licensed under the 2-Clause BSD License.
# See the LICENSE file in this project's root directory for the license
# text.

{.boundChecks: on.}

import os
import strutils
import tables

import snappy as snappy

import jnim
import influx_line_protocol_to_sql
import influx_mysql_cmdline
import influx_mysql_backend
import influx_mysql_backend_db

const MAX_SERVER_SUBMIT_THREADS = 16

type
    JavaOperationException = object of Exception
    ParallelExecutionException = object of Exception

    ParallelExecutionContext = tuple
        hasLast: bool

        entriesLen: int
        threadsSpawned: int
        lineProtocol: string
        sql: array[MAX_SERVER_SUBMIT_THREADS, string]

        lastUsernameObj: jstring
        lastPasswordObj: jstring
        lastDatabaseObj: jstring
        
        lastUsernameString: cstring
        lastPasswordString: cstring
        lastDatabaseString: cstring

    DBQueryContext = tuple
        dbName: cstring
        dbUsername: cstring
        dbPassword: cstring
        sql: cstring

var threads: array[MAX_SERVER_SUBMIT_THREADS, Thread[int]]
var threadInputs: array[MAX_SERVER_SUBMIT_THREADS, Channel[bool]]
var threadOutputs: array[MAX_SERVER_SUBMIT_THREADS, Channel[bool]]
var threadInputsData: array[MAX_SERVER_SUBMIT_THREADS, DBQueryContext]

jnimport:
    # Import a couple of classes
    import com.github.philip_wernersbach.influx_mysql.ignite.InfluxMysqlIgnite
    import com.github.philip_wernersbach.influx_mysql.ignite.ProcessingProxy
    import com.github.philip_wernersbach.influx_mysql.ignite.mpi.CompressedBatchPoints
    import java.util.concurrent.TimeUnit
    import java.util.concurrent.SynchronousQueue[T]

    # Import method declaration
    proc main(clazz: typedesc[InfluxMysqlIgnite], args: openarray[string])
    proc new(clazz: typedesc[InfluxMysqlIgnite], batchPointsBufferId: jint): InfluxMysqlIgnite

    proc setupShutdownHandler(obj: InfluxMysqlIgnite)
    proc continueRunning(obj: InfluxMysqlIgnite): bool
    proc shutdown(obj: InfluxMysqlIgnite)

    proc pointsQueue(clazz: typedesc[ProcessingProxy]): SynchronousQueue[CompressedBatchPoints] {.property.}

    proc MINUTES(clazz: typedesc[TimeUnit]): TimeUnit {.property.}

    proc poll[T](obj: SynchronousQueue[T], timeout: jlong, unit: TimeUnit): T

    proc getUsername(obj: CompressedBatchPoints): jstring
    proc getPassword(obj: CompressedBatchPoints): jstring
    proc getDatabase(obj: CompressedBatchPoints): jstring
    proc getSQLInsertType(obj: CompressedBatchPoints): jint
    proc compressedSchemaLineProtocol(obj: CompressedBatchPoints): jByteArray
    proc compressedLineProtocol(obj: CompressedBatchPoints): jByteArray

template PushLocalFrame*(env: JNIEnvPtr, capacity: jint) =
    if unlikely(jnim.PushLocalFrame(env, capacity) != 0):
        raise newException(JavaOperationException, "JNI PushLocalFrame() failed!")

iterator waitEachWhileContinueRunning(queue: SynchronousQueue[CompressedBatchPoints], ignite: InfluxMysqlIgnite): CompressedBatchPoints {.inline.} =
    let minutes = TimeUnit.MINUTES

    while ignite.continueRunning:
        currentEnv.PushLocalFrame(8)

        try:
            yield queue.poll(8, minutes)
        finally:
            currentEnv.PopLocalFrameNullReturn

proc runDBQueryWithTransaction(id: int) {.thread.} =
    try:
        while threadInputs[id].recv:
            let context = threadInputsData[id]

            context.sql.runDBQueryWithTransaction(context.dbName, context.dbUsername, context.dbPassword)
            threadOutputs[id].send(true)
    except Exception:
        threadOutputs[id].send(false)

        let e = getCurrentException()
        stderr.writeLine(e.getStackTrace() & "Thread " & $id & ": Error: unhandled exception: " & getCurrentExceptionMsg())

        raise e

proc processSQLEntryValuesAndRunDBQueryParallel(context: var ReadLinesContext, dbName: cstring, dbUsername: cstring, dbPassword: cstring,
    parallelContext: var ParallelExecutionContext) {.inline.} =

    var i = 0

    let oldThreadsLen = parallelContext.threadsSpawned
    parallelContext.entriesLen = context.schemaful.inserts.len

    if parallelContext.entriesLen > oldThreadsLen:
        for i in oldThreadsLen..parallelContext.entriesLen-1:
            threadInputs[i].open
            threadOutputs[i].open
            threads[i].createThread(runDBQueryWithTransaction, i)

        parallelContext.threadsSpawned = parallelContext.entriesLen

    for sqlInsert in context.schemaful.inserts.values:
        sqlInsert.sql.addSQLStatementDelimiter
        parallelContext.sql[i].shallowCopy(sqlInsert.sql)

        when defined(logrequests):
            stdout.write("/write: ")
            stdout.writeLine(parallelContext.sql[i])

        threadInputsData[i] = (dbName: dbName, dbUsername: dbUsername, dbPassword: dbPassword, sql: cstring(addr(parallelContext.sql[i][0])))
        threadInputs[i].send(true)
        i += 1

proc ensureParallelExecutionsCompleted(parallelContext: var ParallelExecutionContext) =
    if parallelContext.hasLast:
        for i in 0..parallelContext.entriesLen-1:
            if threadOutputs[i].recv:
                parallelContext.sql[i] = nil
            else:
                raise newException(ParallelExecutionException, "Thread " & $i & "'s execution did not complete correctly!")

        currentEnv.ReleaseStringUTFChars(currentEnv, parallelContext.lastDatabaseObj, parallelContext.lastDatabaseString)
        currentEnv.ReleaseStringUTFChars(currentEnv, parallelContext.lastPasswordObj, parallelContext.lastPasswordString)
        currentEnv.ReleaseStringUTFChars(currentEnv, parallelContext.lastUsernameObj, parallelContext.lastUsernameString)

proc compressedBatchPointsProcessor(ignite: InfluxMysqlIgnite) =
    var parallelContext: ParallelExecutionContext

    parallelContext.hasLast = false
    parallelContext.entriesLen = 0
    parallelContext.threadsSpawned = 0
    parallelContext.lineProtocol = newStringOfCap(SQL_BUFFER_SIZE)

    try:
        for points in ProcessingProxy.pointsQueue.waitEachWhileContinueRunning(ignite):
            if cast[jobject](points).isNil:
                continue

            let usernameObj = points.getUsername
            let usernameString = usernameObj.cstringFromJstring(currentEnv, currentEnv)

            let passwordObj = points.getPassword
            let passwordString = passwordObj.cstringFromJstring(currentEnv, currentEnv)

            let databaseObj = points.getDatabase
            let databaseString = databaseObj.cstringFromJstring(currentEnv, currentEnv)

            let sqlInsertType = case points.getSQLInsertType:
                of 1:
                    SQLInsertType.INSERT
                of 2:
                    SQLInsertType.REPLACE
                else:
                    SQLInsertType.NONE

            var context: ReadLinesContext

            let cslpObj = points.compressedSchemaLineProtocol
            let cslpLen = currentEnv.GetArrayLength(currentEnv, cast[jarray](cslpObj))

            let clpObj = points.compressedLineProtocol
            let clpLen = currentEnv.GetArrayLength(currentEnv, cast[jarray](clpObj))

            if (cslpLen < 1) or (clpLen < 1):
                # Wait until last process is done.
                parallelContext.ensureParallelExecutionsCompleted

                parallelContext.hasLast = false
                return

            let cslpArray = currentEnv.GetByteArrayElements(currentEnv, cslpObj, nil)
            let clpArray = currentEnv.GetByteArrayElements(currentEnv, clpObj, nil)

            try:
                var cslpUncompressedLen = snappy.validateAndGetUncompressedLength(cast[cstring](cslpArray), cslpLen)
                var clpUncompressedLen = snappy.validateAndGetUncompressedLength(cast[cstring](clpArray), clpLen)

                parallelContext.lineProtocol.setLen(cslpUncompressedLen + clpUncompressedLen)

                snappy.uncompressValidatedInputInto(cast[cstring](cslpArray), parallelContext.lineProtocol, cslpLen, cslpUncompressedLen, 0)
                snappy.uncompressValidatedInputInto(cast[cstring](clpArray), parallelContext.lineProtocol, clpLen, clpUncompressedLen, cslpUncompressedLen)

                context = newReadLinesContext(false, sqlInsertType, true, nil)
                context.lines.shallowCopy(parallelContext.lineProtocol)
            finally:
                currentEnv.ReleaseByteArrayElements(currentEnv, clpObj, clpArray, JNI_ABORT)
                currentEnv.ReleaseByteArrayElements(currentEnv, cslpObj, cslpArray, JNI_ABORT)

            try:
                GC_disable()

                # Parse data into the context.
                context.linesToSQLEntryValues

                # Wait until last process is done.
                parallelContext.ensureParallelExecutionsCompleted

                # Process the context.
                context.processSQLEntryValuesAndRunDBQueryParallel(databaseString, usernameString, passwordString,
                    parallelContext)

                parallelContext.lastDatabaseObj = databaseObj
                parallelContext.lastDatabaseString = databaseString
                parallelContext.lastPasswordObj = passwordObj
                parallelContext.lastPasswordString = passwordString
                parallelContext.lastUsernameObj = usernameObj
                parallelContext.lastUsernameString = usernameString

                parallelContext.hasLast = true
            finally:
                try:
                    context.destroyReadLinesContext
                finally:
                    GC_enable()
    finally:
        stdout.writeLine("Shutting down, waiting for influx_mysql_ignite worker threads to exit...")

        for i in 0..parallelContext.threadsSpawned-1:
            threadInputs[i].send(false)
            threads[i].joinThread

        stdout.writeLine("Shutting down, waiting for influx_mysql_ignite worker threads to exit... done.")

proc quitUsage() =
    stderr.writeLine("Usage: influx_mysql <mysql address:mysql port> \"\" <batch points buffer id> [-- java arguments]")
    quit(QuitFailure)

cmdlineMain():
    if params < 3:
        stderr.writeLine("Error: Not enough arguments specified!")
        quitUsage()
    elif (params >= 4) and (paramStr(4) != "--"):
        stderr.writeLine("Error: \"--\" must be fourth argument!")
        quitUsage()

    let bufferId = jint(paramStr(3).parseInt)

    var jvmArgs: seq[string] = @[]

    if params > 5:
        var classpathFixup = false

        for arg in commandLineParams()[5..params-1]:
            if classpathFixup:
                jvmArgs.add("-Djava.class.path=" & arg)
                classpathFixup = false
            elif (arg.len >= 1) and (arg[0] == '-'):
                if arg == "-classpath":
                    classpathFixup = true
                else:
                    jvmArgs.add(arg)

    # Initialize thread-local stuff
    initInfluxLineProtocolToSQL()

    # Start an embedded JVM
    var jvm = newJavaVM(jvmArgs)

    currentEnv.PushLocalFrame(3)

    try:
        let i = InfluxMysqlIgnite.new(bufferId)

        try:
            i.setupShutdownHandler
            i.compressedBatchPointsProcessor
        finally:
            i.shutdown
    except Exception:
        let e = getCurrentException()
        stderr.writeLine(e.getStackTrace() & "Error: unhandled exception: " & getCurrentExceptionMsg())

        raise e
    finally:
        currentEnv.PopLocalFrameNullReturn
        jvm.destroy
