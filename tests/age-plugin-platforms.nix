{ pkgs, nixpkgs }:
let
  inherit (pkgs) lib;
  x86 = import nixpkgs { system = "x86_64-linux"; };
  arm = import nixpkgs { system = "aarch64-linux"; };
  darwin = import nixpkgs { system = "aarch64-darwin"; };
  cross = import nixpkgs {
    localSystem = "x86_64-linux";
    crossSystem = "aarch64-linux";
  };
  nativePlugin = x86.age-plugin-yubikey;
  darwinPlugin = darwin.age-plugin-yubikey;
  crossPlugin = cross.age-plugin-yubikey;
  pubkey = "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq";
  node = plugins: { config.age.rekey.agePlugins = plugins; };
  mixedNodes = {
    "darwin:mac" = node [ darwinPlugin ];
    "nixos:linux" = node [ nativePlugin ];
  };

  # Inspect the generated command without building any foreign packages.
  test = runner: nodes: expectedPlugins: {
    expr = builtins.unsafeDiscardStringContext (
      (import ../nix/lib.nix {
        pkgs = runner;
        inherit nodes;
        userFlake.outPath = toString ../.;
        agePackage = p: p.rage;
      }).ageHostEncrypt
        { config.age.rekey.hostPubkey = pubkey; }
    );
    expected = builtins.unsafeDiscardStringContext ''PATH="$PATH"${
      lib.concatMapStrings (p: ":${lib.escapeShellArg p}/bin") expectedPlugins
    } ${lib.getExe runner.rage} -e -r ${pubkey}'';
  };

  failures = lib.runTests {
    testMixedLinux = test x86 mixedNodes [ nativePlugin ];
    testMixedDarwin = test darwin mixedNodes [ darwinPlugin ];
    testCrossExcludedOnBuildPlatform = test x86 {
      a-cross = node [ crossPlugin ];
      z-native = node [ nativePlugin ];
    } [ nativePlugin ];
    testCrossRetainedOnHostPlatform = test arm { cross = node [ crossPlugin ]; } [ crossPlugin ];
    testForeignOnly = test x86 { foreign = node [ darwinPlugin ]; } [ ];
    testDeduplication = test x86 {
      a = node [ nativePlugin ];
      b = node [ nativePlugin ];
    } [ nativePlugin ];
    testMissingOption = test x86 { host.config.age.rekey = { }; } [ ];
    testEmptyPlugins = test x86 { host = node [ ]; } [ ];
    testStringPackage = test x86 { host = node [ "/plugin" ]; } [ "/plugin" ];
    testMissingMetadata = test x86 { host = node [ { outPath = "/plugin"; } ]; } [ "/plugin" ];
    testSystemFallbackNative = test x86 {
      host = node [ (builtins.removeAttrs nativePlugin [ "stdenv" ]) ];
    } [ nativePlugin ];
    testSystemFallbackForeign = test x86 {
      host = node [ (builtins.removeAttrs darwinPlugin [ "stdenv" ]) ];
    } [ ];
  };
in
assert lib.assertMsg (
  failures == [ ]
) "Age plugin platform tests failed: ${builtins.toJSON failures}";
pkgs.runCommand "age-plugin-platforms" { } ''
  touch "$out"
''
