import os
import strutils
import tables

import snappy as snappy

import jnim
import influx_line_protocol_to_sql
import influx_mysql_cmdline
import influx_mysql_backend

const MAX_SERVER_SUBMIT_THREADS = 16

type
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
    import java.util.concurrent.SynchronousQueue[T]

    # Import method declaration
    proc main(clazz: typedesc[InfluxMysqlIgnite], args: openarray[string])
    proc new(clazz: typedesc[InfluxMysqlIgnite], batchPointsBufferId: jint): InfluxMysqlIgnite

    proc shutdown(obj: InfluxMysqlIgnite)

    proc pointsQueue(clazz: typedesc[ProcessingProxy]): SynchronousQueue[CompressedBatchPoints] {.property.}

    proc take[T](obj: SynchronousQueue[T]): T

    proc getUsername(obj: CompressedBatchPoints): jstring
    proc getPassword(obj: CompressedBatchPoints): jstring
    proc getDatabase(obj: CompressedBatchPoints): jstring
    proc compressedLineProtocol(obj: CompressedBatchPoints): jByteArray

iterator waitEach(queue: SynchronousQueue[CompressedBatchPoints]): CompressedBatchPoints {.inline.} =
    while true:
        discard currentEnv.PushLocalFrame(5)

        try:
            yield queue.take
        finally:
            currentEnv.PopLocalFrameNullReturn

proc runDBQueryWithTransaction(id: int) {.thread.} =
    while threadInputs[id].recv:
        try:
            let context = threadInputsData[id]

            context.sql.runDBQueryWithTransaction(context.dbName, context.dbUsername, context.dbPassword)
            threadOutputs[id].send(true)
        except Exception:
            threadOutputs[id].send(false)
            raise getCurrentException()

proc processSQLEntryValuesAndRunDBQueryParallel(context: var ReadLinesContext, dbName: cstring, dbUsername: cstring, dbPassword: cstring,
    threadsSpawned: var int, sql: var array[MAX_SERVER_SUBMIT_THREADS, string]) {.inline.} =

    let oldThreadsLen = threadsSpawned
    let entriesLen = context.entries.len
    var i = 0

    if entriesLen > oldThreadsLen:
        let sqlCap = SQL_BUFFER_SIZE div entriesLen

        for i in oldThreadsLen..entriesLen-1:
            sql[i] = newStringOfCap(sqlCap)
            
            threadInputs[i].open
            threadOutputs[i].open
            threads[i].createThread(runDBQueryWithTransaction, i)

        threadsSpawned = entriesLen

    for pair in context.entries.pairs:
        pair.sqlEntryValuesToSQL(sql[i]) 

        when defined(logrequests):
            stdout.write("/write: ")
            stdout.writeLine(sql[i])

        threadInputsData[i] = (dbName: dbName, dbUsername: dbUsername, dbPassword: dbPassword, sql: cstring(addr(sql[i][0])))
        threadInputs[i].send(true)
        i += 1
    
    for i in 0..entriesLen-1:
        discard threadOutputs[i].recv
        sql[i].setLen(0)

proc compressedBatchPointsProcessor() =
    var threadsSpawned = 0
    var sql: array[MAX_SERVER_SUBMIT_THREADS, string]

    try:
        for points in ProcessingProxy.pointsQueue.waitEach:
            let usernameObj = points.getUsername
            let usernameString = usernameObj.cstringFromJstring(currentEnv, currentEnv)

            try:
                let passwordObj = points.getPassword
                let passwordString = passwordObj.cstringFromJstring(currentEnv, currentEnv)

                try:
                    let databaseObj = points.getDatabase
                    let databaseString = databaseObj.cstringFromJstring(currentEnv, currentEnv)

                    try:
                        var context: ReadLinesContext

                        let clpObj = points.compressedLineProtocol
                        let clpLen = currentEnv.GetArrayLength(currentEnv, cast[jarray](clpObj))

                        if clpLen < 1:
                            return

                        let clpArray = currentEnv.GetByteArrayElements(currentEnv, clpObj, nil)

                        try:
                            context = newReadLinesContext(false, snappy.uncompress(cast[cstring](clpArray), clpLen))
                        finally:
                            currentEnv.ReleaseByteArrayElements(currentEnv, clpObj, clpArray, JNI_ABORT)

                        try:
                            GC_disable()

                            context.linesToSQLEntryValues
                            context.processSQLEntryValuesAndRunDBQueryParallel(databaseString, usernameString, passwordString, threadsSpawned, sql)
                        finally:
                            try:
                                context.destroyReadLinesContext
                            finally:
                                GC_enable()
                    finally:
                        currentEnv.ReleaseStringUTFChars(currentEnv, databaseObj, databaseString)
                finally:
                    currentEnv.ReleaseStringUTFChars(currentEnv, passwordObj, passwordString)
            finally:
                currentEnv.ReleaseStringUTFChars(currentEnv, usernameObj, usernameString)
    finally:
        stdout.writeLine("Shutting down, waiting for influx_mysql_ignite worker threads to exit...")

        for i in 0..threadsSpawned-1:
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

    var jvmArgs = if params >= 7:
            commandLineParams()[5..params-1]
        else:
            @[]

    var i = 0
    while i < jvmArgs.len:
        if jvmArgs[i] == "-classpath":
            jvmArgs.delete(i)
            jvmArgs[i] = "-Djava.class.path=" & jvmArgs[i]
        elif jvmArgs[i].strip == "":
            jvmArgs.delete(i)

        i += 1

    jvmArgs.delete(i-1)

    # Start an embedded JVM
    let jvm = newJavaVM(jvmArgs)

    discard currentEnv.PushLocalFrame(2)

    try:
        let i = InfluxMysqlIgnite.new(bufferId)

        try:
            compressedBatchPointsProcessor()
        finally:
            i.shutdown
    finally:
        currentEnv.PopLocalFrameNullReturn
