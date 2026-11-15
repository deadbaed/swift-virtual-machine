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

  # Disable debug-info/dSYM generation so SwiftPM does not invoke dsymutil,
  # which on Darwin can demand a full Xcode installation.
  swiftpmFlags = [ "-Xswiftc" "-gnone" ];

  nativeBuildInputs = [
    pkgs.swift
    pkgs.swiftpm
    pkgs.darwin.sigtool
    pkgs.libllvm  # Provides dsymutil if anything still calls it
  ];

  buildInputs = [
    pkgs.apple-sdk_27
  ];

  # Use the default swiftpmHook buildPhase (swift build -c release).
  # We keep a small wrapper so that if an auxiliary Darwin tool such as
  # dsymutil still fails, we continue when the executable was produced.
  buildPhase = ''
    runHook preBuild

    TERM=dumb swift build --disable-sandbox -c release $swiftpmFlags || {
      binPath=$(swiftpmBinPath)
      if [ -f "$binPath/swift-virtual-machine" ]; then
        echo "Build succeeded but an auxiliary tool failed (e.g. dsymutil), continuing..."
      else
        echo "Build failed"
        exit 1
      fi
    }

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp "$(swiftpmBinPath)/swift-virtual-machine" $out/bin/
    runHook postInstall
  '';

  postFixup = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
    codesign --sign - --force \
      --entitlements ${./SwiftVirtualMachine/swift-virtual-machine.entitlements} \
      $out/bin/swift-virtual-machine
  '';
})
