import influxql_to_sql

proc influxQlToSql(influxQl: string): string =
    var series: string
    var period = uint64(0)
    var fillNull = false
    var cache = true

    result = influxQl.influxQlToSql(series, period, fillNull, cache) &
        " /* series=" & (if series != nil: series else: "<nil>") & " period=" & $period & " fillNull=" & $fillNull & " cache=" & $cache & " */"

block:
    for line in stdin.lines:
        stdout.writeLine(line.influxQlToSql)
