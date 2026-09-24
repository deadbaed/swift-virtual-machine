{
  sources ? import ./npins,
  pkgs ? import sources.nixpkgs { },
}:

pkgs.stdenv.mkDerivation {
  pname = "swift-virtual-machine";
  version = "0.1.0";

  src = ./SwiftVirtualMachine;

  nativeBuildInputs = [
    pkgs.swift
    pkgs.swiftpm
    pkgs.apple-sdk
    pkgs.darwin.sigtool
  ];

  buildPhase = ''
    swift build -c release
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp .build/release/swift-virtual-machine $out/bin/
  '';

  postFixup = pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
    codesign --sign - --force \
    --entitlements ${./SwiftVirtualMachine/swift-virtual-machine.entitlements} \
    $out/bin/swift-virtual-machine
  '';
}
