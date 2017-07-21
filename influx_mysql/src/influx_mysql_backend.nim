# influx_mysql_backend.nim
# Part of influx-mysql by Philip Wernersbach <philip.wernersbach@gmail.com>
#
# Copyright (c) 2017, Philip Wernersbach
#
# The source code in this file is licensed under the 2-Clause BSD License.
# See the LICENSE file in this project's root directory for the license
# text.

import strutils
import tables

import stdlib_extra
import reflists
import influx_line_protocol_to_sql

type
    ReadLinesContextSchemaless = ref tuple
        internedStrings: Table[string, ref string]
        entries: Table[ref string, SQLEntryValues]

    ReadLinesContextSchemaful = ref tuple
        entryValues: seq[string]
        inserts: Table[string, ref SQLTableInsert]

    ReadLinesContext* = tuple
        compressed: bool
        destroyed: bool
        sqlInsertType: SQLInsertType
        line: string
        lines: string
        schemaless: ReadLinesContextSchemaless
        schemaful: ReadLinesContextSchemaful
        bop: LineProtocolBufferObjectPool

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
                stdout.write("Debug: ")
                stdout.write("/write: ")
                stdout.writeLine(context.line)

            if context.schemaful != nil:
                context.line.lineProtocolToSQLTableInsert(context.schemaful.inserts, context.schemaful.entryValues, context.bop, context.sqlInsertType)
            else:
                context.line.lineProtocolToSQLEntryValues(context.schemaless.entries, context.schemaless.internedStrings, context.bop)

        lineStart = lineEnd + "\n".len + 1

    if lineStart < context.lines.len:
        let linesNewSize = context.lines.len - lineStart
        
        moveMem(addr(context.lines[0]), addr(context.lines[lineStart]), linesNewSize)
        context.lines.setLen(linesNewSize)
    else:
        context.lines.setLen(0)

template processSQLEntryValues*(entries: var Table[ref string, SQLEntryValues], insertType: SQLInsertType, callbackBlock: untyped) =
    var sql {.inject.} = newStringOfCap(SQL_BUFFER_SIZE)

    for pair in entries.pairs:
        pair.sqlEntryValuesToSQL(sql, insertType)

        callbackBlock
        sql.setLen(0)

template processSQLTableInserts*(inserts: var Table[string, ref SQLTableInsert], callbackBlock: untyped) =
    # Iterating over the keys is a workaround, Nim generates the wrong code in C++ mode for
    # tables.mvalues
    for insertKey in inserts.keys:
        var insert {.inject.} = inserts[insertKey]

        insert.sql.addSQLStatementDelimiter

        callbackBlock

proc newReadLinesContext*(compressed: bool, sqlInsertType: SQLInsertType, schemaful: bool, lines: string): ReadLinesContext {.inline.} =
    if schemaful:
        var schemafulContext: ReadLinesContextSchemaful
        new(schemafulContext)
        schemafulContext[] = (entryValues: newSeq[string](1), inserts: initTable[string, ref SQLTableInsert]())

        result = (compressed: compressed, destroyed: false, sqlInsertType: sqlInsertType, line: "", lines: lines, schemaless: ReadLinesContextSchemaless(nil), schemaful: schemafulContext,
            bop: (freeBstring: 2, bstring: newSeq[string](3), keyAndTagsList: newSeq[int](), fieldsList: newSeq[int]()))

        result.schemaful.entryValues[0] = newStringOfCap(64)
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

        result = (compressed: compressed, destroyed: false, sqlInsertType: sqlInsertType, line: "", lines: lines, schemaless: schemalessContext, schemaful: ReadLinesContextSchemaful(nil),
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
