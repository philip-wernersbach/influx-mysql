# influx-mysql

influx-mysql is a daemon that converts between InfluxDB and MySQL protocol. It
allows time series tools that speak InfluxDB protocol to store and query data
natively in MySQL, using InfluxQL or SQL.

## Compiling
### Dependencies

influx-mysql requires the following dependencies and their headers to be
installed:

* [Qt5Core and Qt5Sql](https://www.qt.io) from Qt 5.
	* Qt5Sql must have the MySQL database driver enabled and compiled as
	  either a plugin or builtin.
		* Most prepackaged Qt5Sql packages have this option enabled.
* [snappy-c](https://github.com/google/snappy) from Google's Snappy project.
* [Nim 0.15.0 or greater](http://nim-lang.org), with the rawrecv standard
  library patch applied (Located at
  `nim_stdlib_rawrecv/nim_stdlib_rawrecv.patch`.)
	* This is a compile time only dependency.
* [Nimble](https://github.com/nim-lang/nimble).
	* This is a compile time only dependency.

### Applying the rawrecv standard library patch to Nim

influx-mysql must be built with Nim 0.15.0 or greater, and the Nim
installation must have the patch located at
`nim_stdlib_rawrecv/nim_stdlib_rawrecv.patch` applied to its standard library.
This patch adds a few low level asynchronous network functions to Nim's
standard library, and it will not affect compiling other Nim software. The
patch can be applied after installing Nim.

For instance, if your Nim installation is located at `/usr/local/nim`, you can
apply the patch with:

```
$ cd /usr/local/nim
$ patch -p1 -i <patch location>
```

### Compiling

After all of the dependencies have been installed, compiling is as simple as
checking out this repository's submodules, installing the Nim package
dependencies with `nimble install` and compiling with `nimble cpp`:

```
$ git submodule update --init # 1
$ nimble install -d # 2
$ mkdir -p bin # 3
$ nimble cpp --out:bin/influx_mysql influx_mysql/src/influx_mysql # 4
$ ./bin/influx_mysql # 5
```

This creates a binary named `influx_mysql` in the `bin` directory.

If the Qt5 or Snappy headers and libraries have not been installed in the C
compiler's standard search paths, the locations of the headers and libraries
have to be passed to Nim via the `--passL` and `--cincludes` arguments, like
so:

```
$ nimble cpp --out:bin/influx_mysql --cincludes:<qt5 path>/include \
  --cincludes:<snappy path>/include --passL:"-L<qt5 path>/lib" \
  --passL:"-L<snappy path>/lib" influx_mysql/src/influx_mysql # 4
```

### Simple compilation & dependency installation

This repository contains a [Nix](http://nixos.org/nix/) derivation that will
automatically install all dependencies and compile influx-mysql. This is the
recommended compilation method. You can build influx-mysql with:

```
$ nix-build . -A influx-mysql # 1
$ ./result/bin/influx_mysql # 2
```

This will install all dependencies and compile influx-mysql, and create a link
to the output binary at `./result/bin/influx_mysql`.

If you want to permanently install influx-mysql to your Nix profile, use a bit
of shell magic:

```
$ nix-env -i $( nix-build . -A influx-mysql --no-out-link ) # 1
$ influx_mysql # 2
```

This will install the `influx_mysql` binary into your Nix profile `bin`
directory.

## Usage

influx-mysql takes arguments of the form:

```
$ influx_mysql <mysql address:mysql port> <influxdb address:influxdb port> [cors allowed origin]
```

For instance, to start an influx-mysql daemon that interfaces with the MySQL
server at `mysqlhost` on port 3306, and binds to all local addresses on port
8086, run:

```
$ influx_mysql mysqlhost:3306 :8086
```

The third argument is for setting the
[Cross-origin resource sharing](https://en.wikipedia.org/wiki/Cross-origin_resource_sharing)
`Access-Control-Allow-Origin` HTTP header. This is only relevant if your setup
involves client browsers talking directly with the influx-mysql server.

## Usage with Grafana

influx-mysql can be used with [Grafana](https://github.com/grafana/grafana).
This requires applying the `grafana_influxdb_dont_quote_everything.patch` patch
to your Grafana sources. This patch modifies Grafana's InfluxQL generator, and
is incompatible with the reference InfluxDB server from InfluxData.

After the patch is applied, you can use influx-mysql with Grafana by setting up
an InfluxDB datasource in Grafana, with the URL pointing to the influx-mysql
server.

The Grafana patch is necessary because InfluxQL statements can literally have
everything quoted (column names, integers, literals, etc.), and InfluxDB will
parse the statement and then convert the quoted strings into the proper types.
SQL databases will happily accept these statements, but the behavior is
undefined when you do SQL comparisons with the quoted strings and the properly
typed database columns.

## Example Usage Scenario

Usage of influx-mysql is fairly straight forward, and involves no
configuration other than supplying the MySQL server address and port, and the
address and port to bind to, as arguments. InfluxDB protocol authentication
and authorization is passed through to the MySQL server, and so is the
client's selected database. influx-mysql will write to and query MySQL table
columns.

The only requirement is that tables accessed via influx-mysql have to contain
a column named `time` with a
[MySQL date or time type](http://dev.mysql.com/doc/refman/5.7/en/datetime.html).
We recommend using `datetime`.

Tables can be written to using the
[InfluxDB line protocol](https://docs.influxdata.com/influxdb/v1.1/guides/writing_data/),
and queried using [InfluxQL](https://docs.influxdata.com/influxdb/v1.1/guides/querying_data/).

For instance, if we create the following database and table in MySQL:

```
CREATE DATABASE influxtest;
USE influxtest;

CREATE TABLE Test (
	time datetime(6) NOT NULL,
	message varchar(254) NOT NULL
);

GRANT ALL ON influxtest.* TO 'root'@'%';
```

We can start influx_mysql by running:

```
influx_mysql mysqlhost:3306 :8086 # 1
```

We can write to the table by running:

```
$ echo 'Test message="Hello World!" 1434055562000000000' | curl -i -XPOST 'http://127.0.0.1:8086/write?db=influxtest&u=root&p=toor' --data-binary @- # 2
```

And then we can query it back using the InfluxDB client:

```
$ influx # 3
Visit https://enterprise.influxdata.com to register for updates, InfluxDB server management, and monitoring.
Connected to http://localhost:8086 version 0.9.3-compatible-influxmysql
InfluxDB shell version: 0.13.0
> auth
username: root
password: toor
> use influxtest
Using database influxtest
> SELECT message FROM Test
name: Test
----------
time			message
1434055562000000000	Hello World!

```
