{.boundChecks: on.}

import sets

import influxql_to_sql

proc influxQlToSql(influxQl: string): string =
    var series: string
    var period = uint64(0)
    var fillNull = false
    var cache = true
    var dizcard = initSet[string]()

    result = influxQl.influxQlToSql(series, period, fillNull, cache, dizcard) &
        " /* series=" & (if series != nil: series else: "<nil>") & " period=" & $period & " fillNull=" & $fillNull & " cache=" & $cache & " discard=" & $dizcard & " */"

block:
    for line in stdin.lines:
        for statement in line.splitInfluxQlStatements:
            stdout.writeLine(statement.influxQlToSql)
