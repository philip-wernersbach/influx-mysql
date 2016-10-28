{ pkgs ? import <nixpkgs> {}, nim ? pkgs.nim }:

nim.overrideDerivation (oldAttrs: { patches = [ ./nim_stdlib_rawrecv.patch ]; })