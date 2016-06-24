{.boundChecks: on.}

import sets

import qdatetime

import influxql_to_sql

proc influxQlToSql(influxQl: string): string =
    var series: string
    var period = uint64(0)
    var resultTransform = SQLResultTransform.UNKNOWN
    var fill = ResultFillType.NONE
    var cache = true
    var fillMin = uint64(0)
    var fillMax = uint64(currentQDateTimeUtc().toMSecsSinceEpoch)
    var dizcard = initSet[string]()

    result = influxQl.influxQlToSql(resultTransform, series, period, fill, fillMin, fillMax, cache, dizcard) &
        " /* resultTransform=" & $resultTransform & " series=" & (if series != nil: series else: "<nil>") & " period=" & $period & " fill=" & $fill & " fillMin=" & $fillMin & " fillMax=" & $fillMax & " cache=" & $cache & " discard=" & $dizcard & " */"

block:
    for line in stdin.lines:
        for statement in line.splitInfluxQlStatements:
            stdout.writeLine(statement.influxQlToSql)
