# influx_mysql_cmdline.nim
# Part of influx-mysql by Philip Wernersbach <philip.wernersbach@gmail.com>
#
# Copyright (c) 2016, Philip Wernersbach
#
# The source code in this file is licensed under the 2-Clause BSD License.
# See the LICENSE file in this project's root directory for the license
# text.

template cmdlineMain*(postamble: untyped): typed {.dirty.} =
    block: 
        var dbHostnameString = "localhost"
        var dbPort = 3306

        var httpServerHostname = ""
        var httpServerPort = 8086

        let params = paramCount()

        if params < 2:
            stderr.writeLine("Error: Not enough arguments specified!")
            quitUsage()

        let dbConnectionInfo = paramStr(1).split(':')
        let httpServerInfo = paramStr(2).split(':')

        case dbConnectionInfo.len:
        of 0:
            discard
        of 1:
            dbHostnameString = dbConnectionInfo[0]
        of 2:
            dbHostnameString = dbConnectionInfo[0]

            try:
                dbPort = dbConnectionInfo[1].parseInt
            except ValueError:
                stderr.writeLine("Error: Invalid mysql port specified!")
                quitUsage()
        else:
            stderr.writeLine("Error: Invalid mysql address, mysql port combination specified!")
            quitUsage()

        case httpServerInfo.len:
        of 0:
            discard
        of 1:
            httpServerHostname = httpServerInfo[0]
        of 2:
            httpServerHostname = httpServerInfo[0]

            try:
                httpServerPort = httpServerInfo[1].parseInt
            except ValueError:
                stderr.writeLine("Error: Invalid influxdb port specified!")
                quitUsage()
        else:
            stderr.writeLine("Error: Invalid influxdb address, influxdb port combination specified!")
            quitUsage()

        initBackendDB(dbHostnameString, dbPort)

        postamble
