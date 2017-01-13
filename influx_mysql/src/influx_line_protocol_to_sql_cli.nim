# influx_line_protocol_to_sql_cli.nim
# Part of influx-mysql by Philip Wernersbach <philip.wernersbach@gmail.com>
#
# Copyright (c) 2017, Philip Wernersbach
#
# The source code in this file is licensed under the 2-Clause BSD License.
# See the LICENSE file in this project's root directory for the license
# text.

{.boundChecks: on.}

import os
import tables
from net import BufferSize

when not defined(disableSnappySupport):
    import snappy as snappy

import influx_mysql_backend
import influx_line_protocol_to_sql

block:
    var compressed = false
    var schemaful = false
    var sqlInsertType = SQLInsertType.INSERT

    let params = paramCount()

    if params > 0:
        for i in countUp(1, params):
            case paramStr(i):
            of "--compressed=true":
                when not defined(disableSnappySupport):
                    compressed = true
                else:
                    raise newException(LibraryError, "Snappy support disabled! To enable, recompile without \"disableSnappySupport\" defined!")
            of "--schemaful=true":
                schemaful = true
            of "--sql_insert_type=replace":
                sqlInsertType = SQLInsertType.REPLACE
            of "--help", "--usage":
                stderr.writeLine("Usage: influx_line_protocol_to_sql_cli [--compressed=true] [--schemaful=true] [--sql_insert_type=replace]")
                quit(QuitSuccess)
            else:
                discard

    var context = newReadLinesContext(compressed, sqlInsertType, schemaful, stdin.readAll)

    when not defined(disableSnappySupport):
        context.uncompressOverwrite

    context.linesToSQLEntryValues

    if context.schemaful != nil:
        context.schemaful.inserts.processSQLTableInserts:
            stdout.write(insert.sql)
    else:
        context.schemaless.entries.processSQLEntryValues(context.sqlInsertType):
            stdout.write(sql)
