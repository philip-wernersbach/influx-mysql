# influxql_to_sql_cli.nim
# Part of influx-mysql by Philip Wernersbach <philip.wernersbach@gmail.com>
#
# Copyright (c) 2016, Philip Wernersbach
#
# The source code in this file is licensed under the 2-Clause BSD License.
# See the LICENSE file in this project's root directory for the license
# text.

{.boundChecks: on.}

import sets

import qt5_qtsql

import influxql_to_sql

proc influxQlToSql(influxQl: string, nowTime: uint64): string =
    var series: string
    var period = uint64(0)
    var resultTransform = SQLResultTransform.UNKNOWN
    var fill = ResultFillType.NONE
    var cache = true
    var fillMin = uint64(0)
    var fillMax = uint64(currentQDateTimeUtc().toMSecsSinceEpoch)
    var dizcard = initSet[string]()

    result = influxQl.influxQlToSql(resultTransform, series, period, fill, fillMin, fillMax, cache, dizcard, nowTime) &
        " /* resultTransform=" & $resultTransform & " series=" & (if series != nil: series else: "<nil>") & " period=" & $period & " fill=" & $fill & " fillMin=" & $fillMin & " fillMax=" & $fillMax &
        " cache=" & $cache & " discard=" & $dizcard & " nowTime=" & $nowTime & " */"

block:
    for line in stdin.lines:
        let nowTime = uint64(currentQDateTimeUtc().toMSecsSinceEpoch)

        for statement in line.splitInfluxQlStatements:
            stdout.writeLine(statement.influxQlToSql(nowTime))
