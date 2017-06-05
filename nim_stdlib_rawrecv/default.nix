/*
Copyright (c) 2003-2016 Eelco Dolstra and the Nixpkgs/NixOS contributors

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

{ pkgs ? import <nixpkgs> {}, stdenv ? pkgs.stdenv, lib ? pkgs.lib, fetchurl ? pkgs.fetchurl, makeWrapper ? pkgs.makeWrapper,
  openssl ? pkgs.openssl, pcre ? pkgs.pcre, readline ? pkgs.readline, sqlite ? pkgs.sqlite }:

stdenv.mkDerivation rec {
  name = "nim-${version}";
  version = "0.17.0";

  src = fetchurl {
    url = "http://nim-lang.org/download/${name}.tar.xz";
    sha256 = "16vsmk4rqnkg9lc9h9jk62ps0x778cdqg6qrs3k6fv2g73cqvq9n";
  };

  NIX_LDFLAGS = [
    "-lcrypto"
    "-lpcre"
    "-lreadline"
    "-lsqlite3"
  ];

  # 2. we could create a separate derivation for the "written in c" version of nim
  #    used for bootstrapping, but koch insists on moving the nim compiler around
  #    as part of building it, so it cannot be read-only

  buildInputs  = [
    makeWrapper
    openssl pcre readline sqlite
  ];

  patches = [ ./nim_stdlib_rawrecv.patch ];

  buildPhase   = ''
    sh build.sh
    ./bin/nim c koch
    ./koch boot  -d:release \
                 -d:useGnuReadline \
                 ${lib.optionals (stdenv.isDarwin || stdenv.isLinux) "-d:nativeStacktrace"}
    ./koch tools -d:release
  '';

  installPhase = ''
    install -Dt $out/bin bin/* koch
    ./koch install $out
    mv $out/nim/bin/* $out/bin/ && rmdir $out/nim/bin
    mv $out/nim/*     $out/     && rmdir $out/nim
    wrapProgram $out/bin/nim \
      --suffix PATH : ${lib.makeBinPath [ stdenv.cc ]}
  '';

  checkPhase = "./koch tests";

  meta = with stdenv.lib; {
    description = "Statically typed, imperative programming language";
    homepage = http://nim-lang.org/;
    license = licenses.mit;
    maintainers = with maintainers; [ ehmry peterhoeg ];
    platforms = with platforms; linux ++ darwin; # arbitrary
  };
}
