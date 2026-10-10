{ pkgs, nixpkgs }:
let
  inherit (pkgs) lib;
  # Model upstream's enable defaults without adding agenix as a flake input.
  baseModule = {
    options = {
      networking.hostName = lib.mkOption {
        type = lib.types.str;
        default = "disable-test";
      };
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [ ];
      };
      warnings = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      age.secrets = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }:
            {
              options = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                };
                name = lib.mkOption {
                  type = lib.types.str;
                  default = name;
                };
                file = lib.mkOption { type = lib.types.path; };
              };
            }
          )
        );
      };
    };
  };
  enableModule =
    { config, ... }:
    {
      options.age.enable = lib.mkOption {
        type = lib.types.bool;
        default = lib.any (secret: secret.enable) (lib.attrValues config.age.secrets);
      };
    };
  evaluate =
    modules:
    lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = [
        baseModule
        (import ../modules/agenix-rekey.nix nixpkgs)
      ] ++ modules;
    };
  disabled = evaluate [
    enableModule
    {
      age.enable = false;
      age.secrets.test = {
        rekeyFile = ./cases/simple/secret.age;
        generator.script = "missing-generator";
      };
      age.rekey.hostPubkey = throw "Disabled hosts must not need a host public key";
      age.rekey.masterIdentities = throw "Disabled hosts must not need master identities";
    }
  ];
  empty = evaluate [ enableModule ];
  enabled = evaluate [
    enableModule
    {
      age.secrets.test.rekeyFile = ./cases/simple/secret.age;
    }
  ];
  legacy = evaluate [
    {
      age.secrets.test.rekeyFile = ./cases/simple/secret.age;
    }
  ];
  mixed = evaluate [
    enableModule
    {
      age.secrets.active.rekeyFile = ./cases/simple/secret.age;
      age.secrets.test = {
        enable = false;
        rekeyFile = throw "Disabled secret source must not be evaluated";
        generator.script = "missing-generator";
      };
    }
  ];
  onlyDisabled = evaluate [
    enableModule
    {
      age.secrets.test.enable = false;
    }
  ];
  userFlake.outPath = toString ./.;
  source = ./cases/simple/secret.age;
  appNodes.host.config = {
    networking.hostName = "disable-test";
    age = {
      rekey = {
        hostPubkey = "age12wqn07q59cgn8258mt3la3ym7nr2cdnh86gp03f6dnm9k3zaqvpq73ny7c";
        masterIdentities = [ ];
        extraEncryptionPubkeys = [ ];
        agePlugins = [ ];
        generatedSecretsDir = null;
        storageMode = "local";
        localStorageDir = userFlake.outPath + "/rekeyed";
        cacheDir = "/tmp/agenix-rekey-test";
        requiredSystemFeatures = [ ];
      };
      secrets = {
        active = {
          id = "active";
          name = "active";
          rekeyFile = source;
          intermediary = false;
          generator = {
            _script = _: "echo active-generator";
            dependencies = [ ];
            tags = [ ];
          };
        };
        disabled = {
          enable = false;
          rekeyFile = throw "Disabled source must not be collected by apps";
          generator = throw "Disabled generator must not be collected by apps";
          intermediary = throw "Disabled intermediary flag must not be evaluated";
        };
        intermediary = {
          id = "intermediary";
          name = "intermediary";
          rekeyFile = ./fixtures/extra-decryption-args.age;
          intermediary = true;
          generator = {
            _script = _: "echo intermediary-generator";
            dependencies = [ ];
            tags = [ ];
          };
        };
      };
    };
  };
  appInputs = {
    inherit userFlake;
    nodes = appNodes;
    agePackage = p: p.rage;
    # Inspect app text without building its runtime dependencies.
    pkgs = pkgs // {
      writeShellScriptBin = _: text: { inherit text; };
    };
  };
  generateText = (import ../apps/generate.nix appInputs).text;
  rekeyText = (import ../apps/rekey.nix appInputs).text;
  derivation = import ../nix/output-derivation.nix {
    appHostPkgs = pkgs;
    hostConfig = appNodes.host.config;
  };
  appLib = import ../nix/lib.nix appInputs;
  # A disabled secret does not receive a rekeyed file definition.
  hasFile = evaluated: builtins.tryEval evaluated.config.age.secrets.test.file;
  select =
    args:
    import ../nix/select-nodes.nix (
      {
        inherit lib;
        nixosConfigurations = { };
        darwinConfigurations = { };
        homeConfigurations = { };
        collectHomeManagerConfigurations = true;
      }
      // args
    );
  node = enable: {
    config.age = {
      inherit enable;
      rekey = { };
    };
  };
  selected = select {
    nixosConfigurations = {
      disabled = (node false) // {
        config = (node false).config // {
          home-manager.users = {
            enabled.age = {
              enable = true;
              rekey = { };
            };
            disabled.age = {
              enable = false;
              rekey = { };
            };
          };
        };
      };
      enabled = node true;
      legacy.config.age.rekey = { };
    };
    darwinConfigurations.disabled = node false;
    homeConfigurations = {
      disabled = node false;
      standalone = node true;
    };
  };
  failures = lib.runTests {
    testDisabledAssertions = {
      expr = disabled.config.assertions;
      expected = [ ];
    };
    testDisabledWarnings = {
      expr = disabled.config.warnings;
      expected = [ ];
    };
    testDisabledFile = {
      expr = (hasFile disabled).success;
      expected = false;
    };
    testEmptyAssertions = {
      expr = empty.config.assertions;
      expected = [ ];
    };
    testEmptyWarnings = {
      expr = empty.config.warnings;
      expected = [ ];
    };
    testEnabledAssertion = {
      expr = (builtins.head enabled.config.assertions).assertion;
      expected = false;
    };
    testEnabledWarning = {
      expr = builtins.length enabled.config.warnings;
      expected = 1;
    };
    testEnabledFile = {
      expr = (hasFile enabled).success;
      expected = true;
    };
    testLegacyAssertion = {
      expr = (builtins.head legacy.config.assertions).assertion;
      expected = false;
    };
    testLegacyFile = {
      expr = (hasFile legacy).success;
      expected = true;
    };
    testMixedAssertions = {
      expr = builtins.length mixed.config.assertions;
      expected = 3;
    };
    testMixedFile = {
      expr = (hasFile mixed).success;
      expected = false;
    };
    testOnlyDisabled = {
      expr = [
        onlyDisabled.config.age.enable
        onlyDisabled.config.assertions
        onlyDisabled.config.warnings
      ];
      expected = [
        false
        [ ]
        [ ]
      ];
    };
    testGenerateSkipsDisabled = {
      expr =
        lib.hasInfix "active-generator" generateText && lib.hasInfix "intermediary-generator" generateText;
      expected = true;
    };
    testRekeySkipsDisabled = {
      expr = lib.hasInfix "-active.age" rekeyText && !(lib.hasInfix "-intermediary.age" rekeyText);
      expected = true;
    };
    testDerivationSkipsDisabled = {
      expr =
        lib.hasInfix "active.age" derivation.installPhase
        && !(lib.hasInfix "intermediary.age" derivation.installPhase);
      expected = true;
    };
    testSecretListsSkipDisabled = {
      expr = appLib.validRelativeSecretPaths;
      expected = [
        "./cases/simple/secret.age"
        "./fixtures/extra-decryption-args.age"
      ];
    };
    testSelectedNodes = {
      expr = builtins.attrNames selected;
      expected = [
        "host-nixos:disabled-user-enabled"
        "nixos:enabled"
        "nixos:legacy"
        "standalone"
      ];
    };
  };
in
assert lib.assertMsg (failures == [ ]) "Disable tests failed: ${builtins.toJSON failures}";
pkgs.runCommand "disable-check" { } ''
  touch "$out"
''
