import unsigned
import strutils

import influx_line_protocol_to_sql

# For some reason InfluxDB implements its own version of SQL that is not compatible
# with standard SQL. The methods in this file are a series of huge hacks to convert
# InfluxQL to SQL. There are several things wrong with them, namely:
#
# 1) They make huge assumptions about the format of the SQL statement when they
#    encounter SQL verbs.
# 2) InfluxQL statements can literally have everything quoted (column names, integers,
#    literals, etc.), and InfluxDB will parse the statement and then convert the
#    quoted strings into the proper types. SQL databases will happily accept these
#    statements, but the behavior is undefined when you do SQL comparisons with the
#    quoted strings and the properly typed database columns.
#
#    Implementing a full InfluxQL parser just to fix this would be a pain, so when
#    "influxql_unquote_everything" is defined, these functions unabashedly unquote 
#    everything. This breaks comparisons with variables that are actually string
#    literals. However, if "influxql_unquote_everything" isn't defined, then if
#    the quoting behavior mentioned in the last paragraph is present in a query, the
#    results are undefined.
# 3) Because of #1 and #2, they will probably mutilate any valid InfluxQL queries that
#    I have not tested (I have not tested any InfluxQL queries other than the basic
#    ones Grafana uses.)
#
# Even though these functions are clearly suboptimal, the alternative is to
# implement a full InfluxQL parser, which would be a pain.

proc collectNumericPrefix(part: string, newPart: var string) =
    for j in countUp(0, part.len - 2):
        if part[j] in {'0'..'9'}:
            newPart.add(part[j])
        else:
            return

proc potentialTimeLiteralToSQLInterval(parts: var seq[string], i: int, intervalType: string) =
    let part = parts[i]
    var newPart = newStringOfCap(part.len + 20)

    if i > 0:
        case parts[i-1]:
        of ">", "<", "=", "==", ">=", "<=":
            case part[part.len-1]:
            of 's':
                newPart.add("FROM_UNIXTIME(")
                part.collectNumericPrefix(newPart)
                newPart.add(")")
                
                parts[i] = newPart
            else:
                discard

            return

    newPart.add("INTERVAL ")
    part.collectNumericPrefix(newPart)

    newPart.add(" ")
    newPart.add(intervalType)

    if newPart.len > (intervalType.len + 10):
        parts[i] = newPart

proc influxQlToSql*(influxQl: string, series: var string, period: var uint64): string =
    var parts = influxQl.split(' ')
    let partsLen = parts.len

    if (partsLen >= 2):
        case parts[0]:
        of "SELECT":
            if (parts[1][parts[1].len-1] == ')') and (parts[1].startsWith("mean(")):
                parts[1][0] = ' '
                parts[1][1] = 'A'
                parts[1][2] = 'V'
                parts[1][3] = 'G'

            if partsLen >= 3:
                for i in countUp(1, partsLen - 1):
                    if parts[i] == "FROM":
                        let seriesPos = i + 1

                        if parts[i - 1] != "*":
                            parts[0] = "SELECT time,"

                        if (partsLen > seriesPos):
                            when defined(influxql_unquote_everything):
                                if (parts[seriesPos][0] == '"') and (parts[seriesPos][parts[seriesPos].len - 1] == '"'):
                                    parts[seriesPos] = parts[seriesPos].unescape

                            series = parts[seriesPos]

                        when defined(influxql_unquote_everything):
                            for j in countDown(i - 1, 1):
                                if (parts[j][parts[j].len - 1] == ')' and parts[j][parts[j].len - 2] == '"'):
                                    let functionName = parts[j].getToken('(', 0)
                                    var newPart = newStringOfCap(parts[j].len - 2)

                                    newPart.add(functionName)
                                    newPart.add('(')
                                    newPart.add(parts[j][functionName.len+2..parts[j].len-3])
                                    newPart.add(")")

                                    parts[j] = newPart

                        let lastPart = parts[partsLen - 1]

                        if (lastPart[lastPart.len - 1] == ')') and lastPart.startsWith("time(") and 
                            (parts[partsLen - 2] == "BY") and (parts[partsLen - 3] == "GROUP"):

                            let intStr = lastPart[5..lastPart.len-3]

                            case lastPart[lastPart.len-2]:
                            of 'u':
                                # Qt doesn't have microsecond precision.
                                period = 0

                                if intStr == "1":
                                    parts[partsLen - 1] = "YEAR(time), MONTH(time), DAY(time), HOUR(time), MINUTE(time), SECOND(time), MICROSECOND(time)"

                            of 's':
                                period = uint64(intStr.parseBiggestInt) * 1000

                                if intStr == "1":
                                    parts[partsLen - 1] = "YEAR(time), MONTH(time), DAY(time), HOUR(time), MINUTE(time), SECOND(time)"
                            of 'm':
                                period = uint64(intStr.parseBiggestInt) * 60000

                                if intStr == "1":
                                    parts[partsLen - 1] = "YEAR(time), MONTH(time), DAY(time), HOUR(time), MINUTE(time)"
                            of 'h':
                                period = uint64(intStr.parseBiggestInt) * 3600000

                                if intStr == "1":
                                    parts[partsLen - 1] = "YEAR(time), MONTH(time), DAY(time), HOUR(time)"
                            of 'd':
                                period = uint64(intStr.parseBiggestInt) * 86400000

                                if intStr == "1":
                                    parts[partsLen - 1] = "YEAR(time), MONTH(time), DAY(time)"
                            of 'w':
                                period = uint64(intStr.parseBiggestInt) * 604800000
                            else:
                                discard

                        parts.add("ORDER BY time ASC")
                        break

        of "DROP":
            if parts[1] == "SERIES":
                parts[0] = "DELETE"
                parts[1] = ""

    for i in countUp(0, parts.len - 1):
        let part = parts[i]

        if part.len < 1:
            continue

        case part:
        of "now()":
            parts[i] = "NOW(6)"
        else:
            if (part[part.len - 1] == ')') and part.startsWith("time("):
                let timeframeType = part[part.len-2]
                let timeframeNumber = part[5..part.len-3]
                
                parts[i] = newStringOfCap(25 + timeframeNumber.len)
                parts[i].add("time DIV ( ")
                parts[i].add(timeframeNumber)

                case timeframeType:
                of 'u':
                    parts[i].add(" * 0.000001 )")
                of 's':
                    parts[i].add(" )")
                of 'm':
                    parts[i].add(" * 60 )")
                of 'h':
                    parts[i].add(" * 3600 )")
                of 'd':
                    parts[i].add(" * 86400 )")
                of 'w':
                    parts[i].add(" * 604800 )")
                else:
                    discard
            else:
                case part[part.len - 1]:
                of 'u':
                    parts.potentialTimeLiteralToSQLInterval(i, "MICROSECOND")
                of 's':
                    parts.potentialTimeLiteralToSQLInterval(i, "SECOND")
                of 'm':
                    parts.potentialTimeLiteralToSQLInterval(i, "MINUTE")
                of 'h':
                    parts.potentialTimeLiteralToSQLInterval(i, "HOUR")
                of 'd':
                    parts.potentialTimeLiteralToSQLInterval(i, "DAY")
                of 'w':
                    parts.potentialTimeLiteralToSQLInterval(i, "WEEK")
                else:
                    when defined(influxql_unquote_everything):
                        case part[part.len - 1]:
                        of '\'':
                            if part[0] == '\'':
                                parts[i] = part[1..part.len - 2]
                        of '\"':
                            if part[0] == '\"':
                                parts[i] = part[1..part.len - 2]
                        else:
                            discard
                    else:
                        discard

    result = parts.join(" ")