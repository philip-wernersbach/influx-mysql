[Package]

version       = "1.0.1"
author        = "Philip Wernersbach"
description   = "A server that translates between InfluxDB and MySQL protocol, and InfluxQL to SQL."
license       = "BSD 2-Clause"

srcDir        = "influx_mysql/src"
bin           = "influx_mysql, influxql_to_sql_cli, influx_mysql_ignite"
backend       = "cpp"

[Deps]

Requires: "nim >= 0.15.0, qt5_qtsql >= 1.1.1, microasynchttpserver >= 0.10.2"
