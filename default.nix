{
	pkgs ? import <nixpkgs> {}, stdenv ? pkgs.stdenv,
	qt5 ? pkgs.qt5, qtbase ? qt5.qtbase, snappy ? pkgs.snappy,
	cacert ? pkgs.cacert, git ? pkgs.git, jdk ? pkgs.jdk8,
	nim ? import ./nim_stdlib_rawrecv { inherit pkgs; }, nimble ? pkgs.nimble.override { inherit nim; },
	nimGc ? "refc", nimAdditionalOptions ? ""
}:

let
	customUnpackCmd = ''
		mkdir -p influx_mysql

		if [ -f $curSrc ] || [ -L $curSrc ]; then
			cp $curSrc influx_mysql/influx_mysql.nimble
		else
			cp -R $curSrc influx_mysql/influx_mysql
		fi
	'';

	influx-mysql-deps =
		stdenv.mkDerivation rec {
			name = "influx-mysql-deps-${version}";
			version = "1.0.0";

			src = ./influx_mysql.nimble;

			buildInputs = [ cacert git nimble nim ];

			unpackCmd = customUnpackCmd;

			buildPhase = ''
				export GIT_SSL_CAINFO=${cacert}/etc/ssl/certs/ca-bundle.crt

				rm -Rf .git
				mkdir -p .nimble

				HOME=$( pwd ) ${nimble}/bin/nimble -y -d install
			'';

			installPhase = ''
				mkdir -p $out/share/influx_mysql_deps
				cp -R .nimble $out/share/influx_mysql_deps
			'';
		}
	;
in
{
	influx-mysql =
		stdenv.mkDerivation rec {
			name = "influx-mysql-${version}";
			version = "1.0.0";

			src = [ ./influx_mysql ./influx_mysql.nimble ];

			buildInputs = [ influx-mysql-deps qtbase cacert git nimble nim ];

			unpackCmd = customUnpackCmd;

			buildPhase = ''
				export GIT_SSL_CAINFO=${cacert}/etc/ssl/certs/ca-bundle.crt

				rm -Rf .git

				mkdir -p bin/

				HOME=${influx-mysql-deps}/share/influx_mysql_deps ${nimble}/bin/nimble -y cpp \
					--cincludes:${qtbase}/include --cincludes:${snappy}/include \
					--passL:"-L${qtbase}/lib" --passL:"-L${snappy}/lib" \
					--gc:${nimGc} ${nimAdditionalOptions} \
					--out:bin/influx_mysql \
					influx_mysql/src/influx_mysql
			'';

			installPhase = ''
				mkdir -p $out/bin
				cp bin/influx_mysql $out/bin
			'';
		}
	;

	influxql-to-sql-cli =
		stdenv.mkDerivation rec {
			name = "influxql-to-sql-cli-${version}";
			version = "1.0.0";

			src = [ ./influx_mysql ./influx_mysql.nimble ];

			buildInputs = [ influx-mysql-deps qtbase cacert git nimble nim ];

			unpackCmd = customUnpackCmd;

			buildPhase = ''
				export GIT_SSL_CAINFO=${cacert}/etc/ssl/certs/ca-bundle.crt

				rm -Rf .git

				mkdir -p bin/

				HOME=${influx-mysql-deps}/share/influx_mysql_deps ${nimble}/bin/nimble -y cpp \
					--cincludes:${qtbase}/include --cincludes:${snappy}/include \
					--passL:"-L${qtbase}/lib" --passL:"-L${snappy}/lib" \
					--gc:${nimGc} ${nimAdditionalOptions} \
					--out:bin/influxql_to_sql_cli \
					influx_mysql/src/influxql_to_sql_cli
			'';

			installPhase = ''
				mkdir -p $out/bin
				cp bin/influxql_to_sql_cli $out/bin
			'';
		}
	;

	influx-mysql-ignite =
		stdenv.mkDerivation rec {
			name = "influx-mysql-ignite-${version}";
			version = "1.0.0";

			src = [ ./influx_mysql ./influx_mysql.nimble ];

			buildInputs = [ influx-mysql-deps qtbase cacert git nimble nim jdk ];

			unpackCmd = customUnpackCmd;

			buildPhase = ''
				export GIT_SSL_CAINFO=${cacert}/etc/ssl/certs/ca-bundle.crt

				rm -Rf .git

				mkdir -p bin/

				HOME=${influx-mysql-deps}/share/influx_mysql_deps ${nimble}/bin/nimble -y cpp \
					--cincludes:${qtbase}/include --cincludes:${snappy}/include \
					--passL:"-L${qtbase}/lib" --passL:"-L${snappy}/lib" \
					--gc:${nimGc} --threads:on ${nimAdditionalOptions} \
					--out:bin/influx_mysql_ignite \
					influx_mysql/src/influx_mysql_ignite
			'';

			installPhase = ''
				mkdir -p $out/bin
				cp bin/influx_mysql_ignite $out/bin
			'';
		}
	;
}
