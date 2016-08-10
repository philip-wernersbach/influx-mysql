import strutils
import sets

import parseutils_extra
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

type
    SQLResultTransform* {.pure.} = enum
        UNKNOWN,
        NONE,
        SHOW_DATABASES

    ResultFillType* {.pure.} = enum
        NONE,
        NULL,
        ZERO

    TimeComparisonType {.pure.} = enum
        NONE,
        LT,
        GT,
        LTE,
        GTE

    TimeArithmeticType {.pure.} = enum
        NONE,
        ADD,
        SUB

proc influxQlTimeLiteralToMillis(iql: string, millis: var uint64, nowTime: uint64): bool =
    let iqlLen = iql.len
    let literalTypePos = iqlLen - 1

    if iqlLen > 0:
        case iql[literalTypePos]:
        of 'u':
            result = (iql.parseBiggestUInt(millis) == literalTypePos)
            millis = millis div 1000
        of 's':
            result = (iql.parseBiggestUInt(millis) == literalTypePos)
            millis *= 1000
        of 'm':
            result = (iql.parseBiggestUInt(millis) == literalTypePos)
            millis *= 60000
        of 'h':
            result = (iql.parseBiggestUInt(millis) == literalTypePos)
            millis *= 3600000
        of 'd':
            result = (iql.parseBiggestUInt(millis) == literalTypePos)
            millis *= 86400000
        of 'w':
            result = (iql.parseBiggestUInt(millis) == literalTypePos)
            millis *= 604800000
        of ')':
            if iql == "now()":
                millis = nowTime
                result = true
        else:
            result = false
    else:
        result = false

iterator splitIndividualStatements(stmts: string, begin: Natural, pos: Natural): string =
    var begin = begin
    var pos = int(pos)
    let length = stmts.len

    while true:
        if (pos > begin) and ((
                (length > (pos + 6)) and
                    (
                        (
                            (stmts[pos + 1] == 'S') and (stmts[pos + 2] == 'E') and (stmts[pos + 3] == 'L') and
                            (stmts[pos + 4] == 'E') and (stmts[pos + 5] == 'C') and (stmts[pos + 6] == 'T')
                        ) or

                        (
                            (stmts[pos + 1] == 'R') and (stmts[pos + 2] == 'A') and (stmts[pos + 3] == 'W') and
                            (stmts[pos + 4] == 'S') and (stmts[pos + 5] == 'Q') and (stmts[pos + 6] == 'L')
                        )
                    )
            ) or

            (
                (length > (pos + 4)) and
                    (stmts[pos + 1] == 'D') and (stmts[pos + 2] == 'R') and (stmts[pos + 3] == 'O') and
                    (stmts[pos + 4] == 'P')
        )):

            yield stmts[int(begin)..pos-1]
            begin = pos + 1

        pos = pos + 1

        if length > begin:
            if length > pos:
                pos = stmts.find(';', pos)
            else:
                yield stmts[int(begin)..length-1]
                break

            if pos < 0:
                yield stmts[int(begin)..length-1]
                break
        else:
            break

iterator splitInfluxQlStatements*(influxQlStatements: string): string =
    for line in influxQlStatements.splitLines:
        let semicolonPosition = line.find(';', 0)

        if semicolonPosition >= 0:
            for statement in line.splitIndividualStatements(0, semicolonPosition):
                yield statement
        else:
            yield line

proc millisToUnixtime(part: var string, millis: uint64) {.inline.} =
    part.setLen(part.len + 20)
    part.setLen(0)

    part.add("FROM_UNIXTIME(")
    part.add($(float64(millis) / 1000))
    part.add(")")

proc intStrToComputedUnixtime(part: var string, intStr: string, computation: string) {.inline.} =
    part.setLen(41 + intStr.len)
    part.setLen(0)

    part.add("UNIX_TIMESTAMP(time) DIV ( ")
    part.add(intStr)
    part.add(computation)

proc influxQlToSql*(influxQl: string, resultTransform: var SQLResultTransform, series: var string,
    period: var uint64, fill: var ResultFillType, fillMin: var uint64, fillMax: var uint64,
    cache: var bool, dizcard: var HashSet[string], nowTime: uint64): string =

    var parts = influxQl.split(' ')
    let partsLen = parts.len
    let lastValidPart = partsLen - 1

    resultTransform = SQLResultTransform.NONE

    if (partsLen >= 2):
        case parts[0]:
        of "SELECT":
            if (parts[1][parts[1].len-1] == ')') and (parts[1].startsWith("mean(")):
                parts[1][0] = ' '
                parts[1][1] = 'A'
                parts[1][2] = 'V'
                parts[1][3] = 'G'

            if partsLen >= 3:
                for i in countUp(1, lastValidPart):
                    if parts[i] == "FROM":
                        let seriesPos = i + 1

                        if parts[i - 1] != "*":
                            parts[0] = "SELECT time,"

                        if (partsLen > seriesPos):
                            let wherePartStart = seriesPos + 1

                            series = parts[seriesPos]

                            for j in countUp(wherePartStart, lastValidPart):
                                if parts[j] == "WHERE":
                                    var isTime = 0
                                    var timeComp = TimeComparisonType.NONE
                                    var timeArithType = TimeArithmeticType.NONE
                                    var timeVal = uint64(0)

                                    var glob = false
                                    var globOpen = 0

                                    var k = j + 1

                                    while k <= lastValidPart:
                                        if glob or (parts[k][0] == '{'):
                                            let lastChar = parts[k].len - 1

                                            if not glob:
                                                globOpen = k
                                                glob = true

                                            if parts[k][lastChar] == '}':
                                                parts[globOpen][0] = '('
                                                parts[k][lastChar] = ')'

                                                glob = false

                                        # Time comparison and arithmetic state machine
                                        case isTime:
                                        of 0:
                                            if parts[k] == "time":
                                                isTime = 1
                                        of 1:
                                            case parts[k]:
                                            of "<":
                                                timeComp = TimeComparisonType.LT
                                                isTime = 2
                                            of ">":
                                                timeComp = TimeComparisonType.GT
                                                isTime = 2
                                            of "<=":
                                                timeComp = TimeComparisonType.LTE
                                                isTime = 2
                                            of ">=":
                                                timeComp = TimeComparisonType.GTE
                                                isTime = 2
                                            else:
                                                isTime = 0
                                        of 2:
                                            if parts[k].influxQlTimeLiteralToMillis(timeVal, nowTime):
                                                # Compute the fill values
                                                case timeComp:
                                                of TimeComparisonType.LT:
                                                    fillMax = timeVal
                                                of TimeComparisonType.GT:
                                                    fillMin = timeVal
                                                of TimeComparisonType.LTE:
                                                    fillMax = timeVal + 1
                                                of TimeComparisonType.GTE:
                                                    fillMin = timeVal - 1
                                                of TimeComparisonType.NONE:
                                                    # This should not happen under normal runtime circumstances
                                                    raise newException(ValueError, "Invalid TimeComparisonType of NONE for stage 3 in time comparison and arithmetic state machine!")

                                                parts[k].millisToUnixtime(timeVal)

                                                isTime = 3
                                            else:
                                                isTime = 0
                                        of 3:
                                            case parts[k]:
                                            of "+":
                                                timeArithType = TimeArithmeticType.ADD
                                                isTime = 4
                                            of "-":
                                                timeArithType = TimeArithmeticType.SUB
                                                isTime = 4
                                            else:
                                                isTime = 0
                                        of 4:
                                            timeVal = 0

                                            if parts[k].influxQlTimeLiteralToMillis(timeVal, nowTime):
                                                # Adjust the fill values
                                                case timeComp:
                                                of TimeComparisonType.LT, TimeComparisonType.LTE:
                                                    case timeArithType:
                                                    of TimeArithmeticType.ADD:
                                                        fillMax += timeVal
                                                        timeVal = fillMax
                                                    of TimeArithmeticType.SUB:
                                                        fillMax -= timeVal
                                                        timeVal = fillMax
                                                    of TimeArithmeticType.NONE:
                                                        # This should not happen under normal runtime circumstances
                                                        raise newException(ValueError, "Invalid TimeArithmeticType of NONE for stage 4 in time comparison and arithmetic state machine!")

                                                    parts[k - 3] = "<"
                                                of TimeComparisonType.GT, TimeComparisonType.GTE:
                                                    case timeArithType:
                                                    of TimeArithmeticType.ADD:
                                                        fillMin += timeVal
                                                        timeVal = fillMin
                                                    of TimeArithmeticType.SUB:
                                                        fillMin -= timeVal
                                                        timeVal = fillMin
                                                    of TimeArithmeticType.NONE:
                                                        # This should not happen under normal runtime circumstances
                                                        raise newException(ValueError, "Invalid TimeArithmeticType of NONE for stage 4 in time comparison and arithmetic state machine!")

                                                    parts[k - 3] = ">"
                                                of TimeComparisonType.NONE:
                                                    # This should not happen under normal runtime circumstances
                                                    raise newException(ValueError, "Invalid TimeComparisonType of NONE for stage 4 in time comparison and arithmetic state machine!")

                                                parts[k - 2] = ""
                                                parts[k - 1] = ""
                                                parts[k].millisToUnixtime(timeVal)

                                            isTime = 0
                                        else:
                                            discard

                                        k += 1

                                    break

                            for j in countDown(lastValidPart, wherePartStart):
                                let jPartLen = parts[j].len

                                if (jPartLen > 0) and (parts[j][jPartLen - 1] == ')'):
                                    if parts[j].startsWith("time(") and (parts[j - 1] == "BY") and (parts[j - 2] == "GROUP"):
                                        let intStr = parts[j][5..jPartLen-3]
                                        fill = ResultFillType.NULL

                                        case parts[j][jPartLen-2]:
                                        of 'u':
                                            # Qt doesn't have microsecond precision.
                                            period = 0

                                            if intStr == "1":
                                                parts[j] = "YEAR(time), MONTH(time), DAY(time), HOUR(time), MINUTE(time), SECOND(time), MICROSECOND(time)"
                                            else:
                                                parts[j].intStrToComputedUnixtime(intStr, " * 0.000001 )")
                                        of 's':
                                            period = uint64(intStr.parseBiggestInt) * 1000

                                            if intStr == "1":
                                                parts[j] = "YEAR(time), MONTH(time), DAY(time), HOUR(time), MINUTE(time), SECOND(time)"
                                            else:
                                                parts[j].intStrToComputedUnixtime(intStr, " )")
                                        of 'm':
                                            period = uint64(intStr.parseBiggestInt) * 60000

                                            if intStr == "1":
                                                parts[j] = "YEAR(time), MONTH(time), DAY(time), HOUR(time), MINUTE(time)"
                                            else:
                                                parts[j].intStrToComputedUnixtime(intStr, " * 60 )")
                                        of 'h':
                                            period = uint64(intStr.parseBiggestInt) * 3600000

                                            if intStr == "1":
                                                parts[j] = "YEAR(time), MONTH(time), DAY(time), HOUR(time)"
                                            else:
                                                parts[j].intStrToComputedUnixtime(intStr, " * 3600 )")
                                        of 'd':
                                            period = uint64(intStr.parseBiggestInt) * 86400000

                                            if intStr == "1":
                                                parts[j] = "YEAR(time), MONTH(time), DAY(time)"
                                            else:
                                                parts[j].intStrToComputedUnixtime(intStr, " * 86400 )")
                                        of 'w':
                                            period = uint64(intStr.parseBiggestInt) * 604800000

                                            if intStr == "1":
                                                parts[j] = "YEAR(time), WEEK(time)"
                                            else:
                                                parts[j].intStrToComputedUnixtime(intStr, " * 604800 )")
                                        else:
                                            discard

                                        let fillPart = j + 1
                                        if partsLen > fillPart:
                                            case parts[fillPart]:
                                            of "fill(null)":
                                                fill = ResultFillType.NULL
                                                parts[fillPart] = ""
                                            of "fill(none)":
                                                fill = ResultFillType.NONE
                                                parts[fillPart] = ""
                                            of "fill(0)":
                                                fill = ResultFillType.ZERO
                                                parts[fillPart] = ""
                                            else:
                                                discard

                                        parts.add("ORDER BY time ASC")

                                    elif parts[j].startsWith("discard("):
                                        dizcard.incl(parts[j][8..jPartLen-2])
                                        parts[j] = ""
                            break

        of "DROP":
            if parts[1] == "SERIES":
                parts[0] = "DELETE"
                parts[1] = ""
        of "RAWSQL":
            parts[0] = ""

            case parts[1]:
            of "NOCACHE":
                parts[1] = ""
                cache = false
            of "CACHE":
                parts[1] = ""
            else:
                discard

            result = parts.join(" ")
            return
        of "SHOW":
            if parts[1] == "DATABASES":
                resultTransform = SQLResultTransform.SHOW_DATABASES

                result = influxQl
                return
        else:
            discard

    result = parts.join(" ")
