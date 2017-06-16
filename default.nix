/*
Copyright (c) 2017 Philip Wernersbach

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

======================================================================

Note: the license above does not apply to the packages built by the
Nix Packages collection, merely to the package descriptions (i.e., Nix
expressions, build scripts, etc.).  Also, the license does not apply
to some of the binaries used for bootstrapping Nixpkgs (e.g.,
pkgs/stdenv/linux/tools/bash).  It also might not apply to patches
included in Nixpkgs, which may be derivative works of the packages to
which they apply.  The aforementioned artifacts are all covered by the
licenses of the respective packages.
*/

{
	pkgs ? import <nixpkgs> {}, stdenv ? pkgs.stdenv, lib ? pkgs.lib,
	makeWrapper ? pkgs.makeWrapper,
	qt5 ? pkgs.qt5, qtbase ? qt5.qtbase, snappy ? pkgs.snappy,
	cacert ? pkgs.cacert, git ? pkgs.git, jdk ? pkgs.jdk8,
	nim ? import ./nim_stdlib_rawrecv { inherit pkgs; },
	nimRelease ? true, nimGc ? "refc", nimAdditionalOptions ? ""
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
			version = "1.0.1";

			src = ./influx_mysql.nimble;

			buildInputs = [ cacert git nim ];

			unpackCmd = customUnpackCmd;

			buildPhase = ''
				export GIT_SSL_CAINFO=${cacert}/etc/ssl/certs/ca-bundle.crt

				rm -Rf .git
				mkdir -p .nimble

				HOME=$( pwd ) ${nim}/bin/nimble -y install -d
			'';

			installPhase = ''
				mkdir -p $out/share/influx_mysql_deps
				cp -R .nimble $out/share/influx_mysql_deps
			'';
		}
	;

	nimSnappyOptions = '' --cincludes:"${snappy.dev}/include" --passL:"-L${snappy.out}/lib" '';
	nimQtOptions = '' --passC:-std=c++11 --cincludes:"${qtbase.dev}/include" --cincludes:"${qtbase.out}/lib" --passL:"-L${qtbase.out}/lib" ''
		+ lib.optionalString stdenv.isDarwin '' --passC:-F${qtbase.dev}/include --passC:-F${qtbase.out}/lib \
				--passL:-F${qtbase.dev}/include --passL:-F${qtbase.out}/lib '';
in
{
	influx-mysql =
		stdenv.mkDerivation rec {
			name = "influx-mysql-${version}";
			version = "1.0.1";

			src = [ ./influx_mysql ./influx_mysql.nimble ];

			buildInputs = [ makeWrapper influx-mysql-deps qtbase.out qtbase.dev snappy.out snappy.dev cacert git nim ];

			unpackCmd = customUnpackCmd;

			buildPhase = ''
				export GIT_SSL_CAINFO=${cacert}/etc/ssl/certs/ca-bundle.crt

				rm -Rf .git

				mkdir -p bin/ build_support/

				# These wrappers are a workaround for a bug in the Nim compiler.
				# When "-std=c++11" is specified, for some reason Nim calls the C compiler instead of the C++ one.
				makeWrapper clang++ build_support/clang
				makeWrapper g++ build_support/gcc

				PATH=build_support:$PATH HOME=${influx-mysql-deps}/share/influx_mysql_deps ${nim}/bin/nimble -y cpp \
					${nimSnappyOptions} ${nimQtOptions} \
					'' + lib.optionalString nimRelease '' -d:release '' + '' --gc:${nimGc} ${nimAdditionalOptions} \
					--out:bin/influx_mysql \
					influx_mysql/src/influx_mysql.nim
			'';

			installPhase = ''
				mkdir -p $out/bin
				cp bin/influx_mysql $out/bin
			'' + lib.optionalString stdenv.isDarwin ''
				wrapProgram $out/bin/influx_mysql --set DYLD_FRAMEWORK_PATH /System/Library/Frameworks
			'';
		}
	;

	influxql-to-sql-cli =
		stdenv.mkDerivation rec {
			name = "influxql-to-sql-cli-${version}";
			version = "1.0.1";

			src = [ ./influx_mysql ./influx_mysql.nimble ];

			buildInputs = [ makeWrapper influx-mysql-deps qtbase.out qtbase.dev snappy.out snappy.dev cacert git nim ];

			unpackCmd = customUnpackCmd;

			buildPhase = ''
				export GIT_SSL_CAINFO=${cacert}/etc/ssl/certs/ca-bundle.crt

				rm -Rf .git

				mkdir -p bin/ build_support/

				# These wrappers are a workaround for a bug in the Nim compiler.
				# When "-std=c++11" is specified, for some reason Nim calls the C compiler instead of the C++ one.
				makeWrapper clang++ build_support/clang
				makeWrapper g++ build_support/gcc

				PATH=build_support:$PATH HOME=${influx-mysql-deps}/share/influx_mysql_deps ${nim}/bin/nimble -y cpp \
					${nimSnappyOptions} ${nimQtOptions} \
					'' + lib.optionalString nimRelease '' -d:release '' + '' --gc:${nimGc} ${nimAdditionalOptions} \
					--out:bin/influxql_to_sql_cli \
					influx_mysql/src/influxql_to_sql_cli.nim
			'';

			installPhase = ''
				mkdir -p $out/bin
				cp bin/influxql_to_sql_cli $out/bin
			'' + lib.optionalString stdenv.isDarwin ''
				wrapProgram $out/bin/influxql_to_sql_cli --set DYLD_FRAMEWORK_PATH /System/Library/Frameworks
			'';
		}
	;

	influx-line-protocol-to-sql-cli =
		stdenv.mkDerivation rec {
			name = "influx-line-protocol-to-sql-cli-${version}";
			version = "1.0.1";

			src = [ ./influx_mysql ./influx_mysql.nimble ];

			buildInputs = [ influx-mysql-deps snappy.out snappy.dev cacert git nim ];

			unpackCmd = customUnpackCmd;

			buildPhase = ''
				export GIT_SSL_CAINFO=${cacert}/etc/ssl/certs/ca-bundle.crt

				rm -Rf .git

				mkdir -p bin/

				HOME=${influx-mysql-deps}/share/influx_mysql_deps ${nim}/bin/nimble -y c \
					${nimSnappyOptions} \
					'' + lib.optionalString nimRelease '' -d:release '' + '' --gc:${nimGc} ${nimAdditionalOptions} \
					--out:bin/influx_line_protocol_to_sql_cli \
					influx_mysql/src/influx_line_protocol_to_sql_cli.nim
			'';

			installPhase = ''
				mkdir -p $out/bin
				cp bin/influx_line_protocol_to_sql_cli $out/bin
			'';
		}
	;

	influx-mysql-ignite =
		stdenv.mkDerivation rec {
			name = "influx-mysql-ignite-${version}";
			version = "1.0.1";

			src = [ ./influx_mysql ./influx_mysql.nimble ];

			buildInputs = [ makeWrapper influx-mysql-deps qtbase.out qtbase.dev snappy.out snappy.dev cacert git nim jdk ];

			unpackCmd = customUnpackCmd;

			buildPhase = ''
				export GIT_SSL_CAINFO=${cacert}/etc/ssl/certs/ca-bundle.crt

				rm -Rf .git

				mkdir -p bin/ build_support/

				# These wrappers are a workaround for a bug in the Nim compiler.
				# When "-std=c++11" is specified, for some reason Nim calls the C compiler instead of the C++ one.
				makeWrapper clang++ build_support/clang
				makeWrapper g++ build_support/gcc

				PATH=build_support:$PATH HOME=${influx-mysql-deps}/share/influx_mysql_deps ${nim}/bin/nimble -y cpp \
					${nimSnappyOptions} ${nimQtOptions} \
					--gc:${nimGc} --threads:on ${nimAdditionalOptions} \
					--out:bin/influx_mysql_ignite \
					influx_mysql/src/influx_mysql_ignite.nim
			'';

			installPhase = ''
				mkdir -p $out/bin
				cp bin/influx_mysql_ignite $out/bin
			'' + lib.optionalString stdenv.isDarwin ''
				wrapProgram $out/bin/influx_mysql_ignite --set DYLD_FRAMEWORK_PATH /System/Library/Frameworks
			'';
		}
	;
}
