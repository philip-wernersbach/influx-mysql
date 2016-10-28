[Package]

version       = "1.0.0"
author        = "Philip Wernersbach"
description   = "A server that translates between InfluxDB and MySQL protocol, and InfluxQL to SQL."
license       = "BSD 2-Clause"

bin           = "influx_mysql"
backend       = "cpp"

[Deps]

Requires: "nim >= 0.15.0, qt5_qtsql >= 1.0.1, microasynchttpserver >= 0.9.5"
