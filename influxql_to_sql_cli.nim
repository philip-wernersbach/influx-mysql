import influxql_to_sql

proc influxQlToSql(influxQl: string): string =
    var series: string
    var period = uint64(0)

    result = influxQl.influxQlToSql(series, period)

block:
    for line in stdin.lines:
        stdout.write(line.influxQlToSql)
