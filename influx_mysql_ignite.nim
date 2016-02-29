import os
import strutils

import snappy as snappy

import jnim
import influx_mysql_cmdline
import influx_mysql_backend

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

proc compressedBatchPointsProcessor() =
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
                        context.processSQLEntryValuesAndRunDBQuery(databaseString, usernameString, passwordString)
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
