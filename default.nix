{
  sources ? import ./npins,
  pkgs ? import sources.nixpkgs { },
}:

pkgs.stdenv.mkDerivation (finalAttrs: {
  pname = "swift-virtual-machine";
  version = "0.1.0";

  src = pkgs.lib.cleanSourceWith {
    src = ./SwiftVirtualMachine;
    filter = path: type:
      let
        base = baseNameOf path;
        # Prune the local SwiftPM build tree so it doesn't get copied to the Nix store.
        isBuildArtifact = base == ".build" || pkgs.lib.strings.hasInfix "/.build/" path;
      in
      !isBuildArtifact;
  };

  swiftpmDeps = pkgs.fetchSwiftPMDeps {
    inherit (finalAttrs) src;
    hash = "sha256-OQSjjkgWxCVGt5HO/drHGLGioel2WDdKiPloR/Pu1QE=";
  };

  nativeBuildInputs = [
    pkgs.swift
    pkgs.swiftpm
    pkgs.darwin.sigtool
  ];

  buildInputs = [
    pkgs.apple-sdk_27
  ];

  postFixup = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
    codesign --sign - --force \
      --entitlements ${./SwiftVirtualMachine/swift-virtual-machine.entitlements} \
      $out/bin/swift-virtual-machine
  '';
})
