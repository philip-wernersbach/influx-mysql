{.boundChecks: on.}

import sets

import influxql_to_sql

proc influxQlToSql(influxQl: string): string =
    var series: string
    var period = uint64(0)
    var fill = ResultFillType.NONE
    var cache = true
    var resultTransform = SQLResultTransform.UNKNOWN
    var dizcard = initSet[string]()

    result = influxQl.influxQlToSql(resultTransform, series, period, fill, cache, dizcard) &
        " /* resultTransform=" & $resultTransform & " series=" & (if series != nil: series else: "<nil>") & " period=" & $period & " fill=" & $fill & " cache=" & $cache & " discard=" & $dizcard & " */"

block:
    for line in stdin.lines:
        for statement in line.splitInfluxQlStatements:
            stdout.writeLine(statement.influxQlToSql)
