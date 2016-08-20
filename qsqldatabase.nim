import asyncdispatch

const MYSQL_H = "<mysql.h>"

type
    MySql {.final, header: MYSQL_H, importc: "MYSQL", incompleteStruct.} = object
    MySqlRes {.final, header: MYSQL_H, importc: "MYSQL_RES", incompleteStruct.} = object
    MySqlRow {.final, header: MYSQL_H, importc: "MYSQL_ROW", incompleteStruct.} = object
    MySqlField {.final, header: MYSQL_H, importc: "MYSQL_FIELD", incompleteStruct.} = object
        name: cstring
        `type`: MySqlFieldType

    MySqlOption {.final, header: MYSQL_H, importc: "enum mysql_option".} = enum
        MYSQL_OPT_CONNECT_TIMEOUT, MYSQL_OPT_COMPRESS, MYSQL_OPT_NAMED_PIPE,
        MYSQL_INIT_COMMAND, MYSQL_READ_DEFAULT_FILE, MYSQL_READ_DEFAULT_GROUP,
        MYSQL_SET_CHARSET_DIR, MYSQL_SET_CHARSET_NAME, MYSQL_OPT_LOCAL_INFILE,
        MYSQL_OPT_PROTOCOL, MYSQL_SHARED_MEMORY_BASE_NAME, MYSQL_OPT_READ_TIMEOUT,
        MYSQL_OPT_WRITE_TIMEOUT, MYSQL_OPT_USE_RESULT,
        MYSQL_OPT_USE_REMOTE_CONNECTION, MYSQL_OPT_USE_EMBEDDED_CONNECTION,
        MYSQL_OPT_GUESS_CONNECTION, MYSQL_SET_CLIENT_IP, MYSQL_SECURE_AUTH,
        MYSQL_REPORT_DATA_TRUNCATION, MYSQL_OPT_RECONNECT,
        MYSQL_OPT_SSL_VERIFY_SERVER_CERT, MYSQL_PLUGIN_DIR, MYSQL_DEFAULT_AUTH,
        MYSQL_OPT_BIND,
        MYSQL_OPT_SSL_KEY, MYSQL_OPT_SSL_CERT, 
        MYSQL_OPT_SSL_CA, MYSQL_OPT_SSL_CAPATH, MYSQL_OPT_SSL_CIPHER,
        MYSQL_OPT_SSL_CRL, MYSQL_OPT_SSL_CRLPATH,
        MYSQL_OPT_CONNECT_ATTR_RESET, MYSQL_OPT_CONNECT_ATTR_ADD,
        MYSQL_OPT_CONNECT_ATTR_DELETE,
        MYSQL_SERVER_PUBLIC_KEY,
        MYSQL_ENABLE_CLEARTEXT_PLUGIN,
        MYSQL_OPT_CAN_HANDLE_EXPIRED_PASSWORDS,

        MYSQL_PROGRESS_CALLBACK=5999,
        MYSQL_OPT_NONBLOCK,
        MYSQL_OPT_USE_THREAD_SPECIFIC_MEMORY

    MySqlFieldType {.final, header: MYSQL_H, importc: "enum enum_field_types".} = enum
        MYSQL_TYPE_DECIMAL, MYSQL_TYPE_TINY,
        MYSQL_TYPE_SHORT,  MYSQL_TYPE_LONG,
        MYSQL_TYPE_FLOAT,  MYSQL_TYPE_DOUBLE,
        MYSQL_TYPE_NULL,   MYSQL_TYPE_TIMESTAMP,
        MYSQL_TYPE_LONGLONG,MYSQL_TYPE_INT24,
        MYSQL_TYPE_DATE,   MYSQL_TYPE_TIME,
        MYSQL_TYPE_DATETIME, MYSQL_TYPE_YEAR,
        MYSQL_TYPE_NEWDATE, MYSQL_TYPE_VARCHAR,
        MYSQL_TYPE_BIT,

        MYSQL_TYPE_TIMESTAMP2,
        MYSQL_TYPE_DATETIME2,
        MYSQL_TYPE_TIME2,

        MYSQL_TYPE_NEWDECIMAL=246,
        MYSQL_TYPE_ENUM=247,
        MYSQL_TYPE_SET=248,
        MYSQL_TYPE_TINY_BLOB=249,
        MYSQL_TYPE_MEDIUM_BLOB=250,
        MYSQL_TYPE_LONG_BLOB=251,
        MYSQL_TYPE_BLOB=252,
        MYSQL_TYPE_VAR_STRING=253,
        MYSQL_TYPE_STRING=254,
        MYSQL_TYPE_GEOMETRY=255,
        MAX_NO_FIELD_TYPES

    QSqlDatabaseObj = tuple
        hostname: cstring
        databaseName: cstring
        port: cuint
        mySql: MySql
        status: cint
        ret: pointer
        fd: AsyncFD
        waitRead: bool
        waitWrite: bool
        asyncResult: Future[ref QSqlDatabaseObj]

    QSqlQueryObj = tuple
        row: MySqlRow
        db: ref QSqlDatabaseObj
        asyncResult: Future[ref QSqlQueryObj]
        sql: string

    QSqlException = object of IOError

const MYSQL_WAIT_READ = cint(1)
const MYSQL_WAIT_WRITE = cint(2)
const MYSQL_WAIT_EXCEPT = cint(4)
const MYSQL_WAIT_TIMEOUT = cint(8)

template newQSqlError(error: string): expr =
    newException(QSqlException, error)

proc initMySqlLibrary(argc: cint, argv: ptr cstring, groups: ptr cstring) {.header: MYSQL_H, importc: "mysql_library_init".}
proc unInitMySqlLibrary() {.header: MYSQL_H, importc: "mysql_library_end".}
proc initMySql(mysql: var MySql) {.header: MYSQL_H, importc: "mysql_init".}

proc realConnectStart(ret: ptr pointer, mysql: var MySql,
    host: cstring, user: cstring, passwd: cstring, db: cstring, port: cuint,
    unixSocket: cstring, clientflag: culong): cint {.header: MYSQL_H, importc: "mysql_real_connect_start".}

proc realConnectCont(ret: ptr pointer, mysql: var MySql,
    status: cint): cint {.header: MYSQL_H, importc: "mysql_real_connect_cont".}

proc realQueryStart(ret: ptr cint, mysql: var MySql,
    query: cstring, length: culong): cint {.header: MYSQL_H, importc: "mysql_real_query_start".}

proc realQueryCont(ret: ptr cint, mysql: var MySql,
    status: cint): cint {.header: MYSQL_H, importc: "mysql_real_query_cont".}

proc fetchRowStart(ret: ptr MySqlRow, res: ptr MySqlRes): cint {.header: MYSQL_H, importc: "mysql_fetch_row_start".}
proc fetchRowCont(ret: ptr MySqlRow, res: ptr MySqlRes,
    status: cint): cint {.header: MYSQL_H, importc: "mysql_fetch_row_cont".}

proc fetchField(res: ptr MySqlRes): ptr MySqlField {.header: MYSQL_H, importc: "mysql_fetch_field".}
proc results(mysql: var MySql): ptr MySqlRes {.header: MYSQL_H, importc: "mysql_use_result".}
proc options(mysql: var MySql, option: MySqlOption, arg: cstring) {.header: MYSQL_H, importc: "mysql_options".}
proc getSocket(mysql: var MySql): cint {.header: MYSQL_H, importc: "mysql_get_socket".}
proc errno(mysql: var MySql): cuint {.header: MYSQL_H, importc: "mysql_errno".}


proc setHostName(db: var QSqlDatabaseObj, hostname: cstring) =
    db.hostname = hostname

proc setPort(db: var QSqlDatabaseObj, port: cuint) =
    db.port = port

proc setDatabaseName(db: var QSqlDatabaseObj, databaseName: cstring) =
    db.databaseName = databaseName

proc newQSqlDatabase(typ: cstring, connectionName: cstring): QSqlDatabaseObj {.inline.} =
    result.hostname = ""
    result.databaseName = ""
    result.port = 0
    result.status = 0
    result.ret = nil
    result.fd = AsyncFD(-1)
    result.asyncResult = newFuture[ref QSqlDatabaseObj]("newQSqlDatabase")

    result.asyncResult.fail(newQSqlError("No operation performed!"))

    initMySql(result.mySql)

proc processResult(db: ref QSqlDatabaseObj, failureMessage: string, testIsNil: bool) =
    if (not db.waitRead) and (not db.waitWrite):
        if testIsNil:
            if db.ret != nil:
                debugEcho "Completing"
                db.asyncResult.complete(db)
            else:
                db.asyncresult.fail(newQSqlError(failureMessage))
        else:
            if db.ret == nil:
                debugEcho "Completing"
                db.asyncResult.complete(db)
            else:
                db.asyncresult.fail(newQSqlError(failureMessage))

template processAsync(db: ref QSqlDatabaseObj, failureMessage: string, testIsNil: bool, contProc: typed): typed =
    var processResultImmediately = true

    db.asyncResult = newFuture[ref QSqlDatabaseObj]("processAsync")

    db.waitRead = ((db.status and MYSQL_WAIT_READ) != 0)
    db.waitWrite = ((db.status and MYSQL_WAIT_WRITE) != 0)
    
    if not db.waitRead:
      db.waitRead = ((db.status and MYSQL_WAIT_EXCEPT) != 0)

    if db.waitRead:
        processResultImmediately = false

        db.fd.addRead(proc (s: AsyncFD): bool = 
            debugEcho "read"
            db.status = contProc
            db.waitRead = ((db.status and MYSQL_WAIT_READ) != 0)

            if not db.waitRead:
              db.waitRead = ((db.status and MYSQL_WAIT_EXCEPT) != 0)

            if db.waitRead:
                result = false
            else:
                db.processResult(failureMessage, testIsNil)
                result = true
        )

    if db.waitWrite:
        processResultImmediately = false

        db.fd.addWrite(proc (s: AsyncFD): bool = 
            debugEcho "write"
            db.status = contProc
            db.waitWrite = ((db.status and MYSQL_WAIT_WRITE) != 0)

            if db.waitWrite:
                result = false
            else:
                db.processResult(failureMessage, testIsNil)
                result = true
        )

    if processResultImmediately:
        db.processResult(failureMessage, testIsNil)

proc openAsync(db: ref QSqlDatabaseObj, user: cstring, password: cstring) =
    db.ret = nil

    db.mySql.options(MYSQL_OPT_NONBLOCK, nil)
    db.status = realConnectStart(addr(db.ret), db.mySql, db.hostname, user, password, db.databaseName, db.port, nil, 0)

    db.fd = AsyncFD(db.mySql.getSocket)
    db.fd.register

    db.processAsync("Failed to connect to MySQL database!", true):
        realConnectCont(addr(db.ret), db.mySql, db.status)

proc qSqlQuery(db: ref QSqlDatabaseObj): QSqlQueryObj =
    result.db = db
    result.sql = ""
    result.asyncResult = newFuture[ref QSqlQueryObj]("qSqlQuery")

    result.asyncResult.fail(newQSqlError("No operation performed!"))

proc prepare(query: var QSqlQueryObj, sql: string) =
    query.sql = sql

proc execAsync(query: ref QSqlQueryObj) =
    query.db.ret = nil

    query.db.status = realQueryStart(cast[ptr cint](addr(query.db.ret)), query.db.mysql, query.sql, culong(query.sql.len))

    query.db.processAsync("Failed to execute MySQL query!", false):
        realQueryCont(cast[ptr cint](addr(query.db.ret)), query.db.mysql, query.db.status)

    query.asyncResult = newFuture[ref QSqlQueryObj]("execAsync")
    query.db.asyncResult.callback = (proc (asyncResult: Future[ref QSqlDatabaseObj]) =
        try:
            discard asyncResult.read
            query.asyncResult.complete(query)
        except Exception:
            asyncResult.fail(getCurrentException())
    )

proc nextAsync(query: ref QSqlQueryObj, results: ptr MySqlRes) =
    query.db.ret = nil

    query.db.status = fetchRowStart(addr(query.row), results)

    query.db.processAsync("Failed to retrieve next row!", true):
        fetchRowCont(addr(query.row), results, query.db.status)

    query.asyncResult = newFuture[ref QSqlQueryObj]("execAsync")
    query.db.asyncResult.callback = (proc (asyncResult: Future[ref QSqlDatabaseObj]) =
        try:
            discard asyncResult.read
            query.asyncResult.complete(query)
        except Exception:
            query.asyncResult.fail(getCurrentException())
    )

block:
    proc getAllRows(query: ref QSqlQueryObj, results: ptr MySqlRes) =
        debugEcho "row start"

        query.nextAsync(results)

        query.asyncResult.callback = (proc (asyncResult: Future[ref QSqlQueryObj]) =
            try:
                let query = asyncResult.read

                debugEcho "row end"

                getAllRows(query, results)
            except Exception:
                if query.db.mysql.errno != 0:
                    raise getCurrentException()
                else:
                    debugEcho "supressed exception"
        )

    initMySqlLibrary(0, nil, nil)

    var db: ref QSqlDatabaseObj
    new(db)

    db[] = newQSqlDatabase(nil, nil)
    db[].setHostname("localhost")
    db[].setPort(3309)
    db[].setDatabaseName("emf")

    debugEcho "open start"
    db.openAsync("root", "epac")

    db.asyncResult.callback = (proc(asyncResult: Future[ref QSqlDatabaseObj]) =
        let db = asyncResult.read
        debugEcho "open done"

        debugEcho "query start"
        var query: ref QSqlQueryObj
        new(query)

        query[] = db.qSqlQuery
        query[].prepare("SELECT * FROM job LIMIT 100")
        query.execAsync

        query.asyncResult.callback = (proc(asyncResult: Future[ref QSqlQueryObj]) =
            let query = asyncResult.read
            debugEcho "query done"

            debugEcho "results start"
            let results = query.db.mysql.results

            if results == nil:
                raise newQSqlError("Failed to get results from MySQL query!")
            debugEcho "results done"

            debugEcho "fetchField start"
            var field = results.fetchField
            debugEcho "fetchField done"

            debugEcho ""
            while field != nil:
                debugEcho field.name
                debugEcho $field.type
                field = results.fetchField
            debugEcho ""

            query.getAllRows(results)
        )
    )

    runForever()

    unInitMySqlLibrary()
