{
  pkgs,
  agenix-rekey,
  flake-parts,
}:
let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;
  userFlake.outPath = toString ./.;
  pubkey = "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq";
  extraDecryptionArgs = [
    "--test-option"
    "path with spaces"
    ""
    "single'quote"
    ''"double quotes"''
    "$HOME"
    "$(touch unexpected)"
    "`touch unexpected`"
    "; touch unexpected;"
    "*"
    "line\nbreak"
  ];
  recorder = pkgs.writeShellScriptBin "age-recorder" ''
    printf '%s\0' "$@" > "$RECORD_ARGS"
  '';
  plugin = pkgs.writeScriptBin "age-plugin-rekeytest" (
    "#!${pkgs.python3}/bin/python3\n" + builtins.readFile ./age-plugin-rekeytest.py
  );
  pluginRecipient = "age1rekeytest172ptak";
  identities = [
    {
      identity = "/test-identity";
      inherit pubkey;
    }
    {
      identity = "/unused-identity";
      pubkey = "second-recipient";
    }
  ];
  nodes.host.config.age = {
    rekey = {
      masterIdentities = identities;
      agePlugins = [ ];
      extraEncryptionPubkeys = [ ];
      generatedSecretsDir = null;
      storageMode = "local";
      localStorageDir = userFlake.outPath + "/rekeyed";
      hostPubkey = pubkey;
    };
    secrets.test = {
      id = "test";
      name = "test";
      intermediary = false;
      rekeyFile = ./fixtures/extra-decryption-args.age;
      generator = {
        _script = _: "printf test";
        dependencies = [ ];
        tags = [ ];
      };
    };
  };
  mkLib =
    args:
    import ../nix/lib.nix (
      {
        inherit pkgs userFlake nodes;
        agePackage = _: recorder;
      }
      // args
    );
  commands =
    args:
    let
      ageLib = mkLib args;
    in
    {
      decrypt = ageLib.ageMasterDecrypt;
      encrypt = ageLib.ageMasterEncrypt;
    };

  # Exercise all apps, including generate with a nonempty generator list.
  configure =
    args:
    (agenix-rekey.configure (
      {
        inherit userFlake;
        nixosConfigurations = nodes;
        systems = [ system ];
        agePackage = _: recorder;
      }
      // args
    )).${system};
  parts =
    args:
    let
      inputs = {
        inherit self;
        inherit (agenix-rekey.inputs) nixpkgs;
      };
      self =
        (flake-parts.lib.mkFlake { inherit inputs; } {
          systems = [ system ];
          imports = [ ../flake-module.nix ];
          flake.nixosConfigurations = nodes;
          perSystem.agenix-rekey = {
            inherit pkgs;
            agePackage = recorder;
          } // args;
        })
        // {
          inherit inputs;
          inherit (userFlake) outPath;
        };
    in
    self.agenix-rekey.${system};
  appSets = [
    {
      apps = configure { };
      extra = [ ];
    }
    {
      apps = parts { };
      extra = [ ];
    }
    {
      apps = configure { inherit extraDecryptionArgs; };
      extra = extraDecryptionArgs;
    }
    {
      apps = parts { inherit extraDecryptionArgs; };
      extra = extraDecryptionArgs;
    }
  ];

  # The host module cannot see app options. It must accept recipient-only setups
  # while continuing to reject configurations with no encryption targets at all.
  hasEncryptionTarget =
    masterIdentities: extraEncryptionPubkeys:
    let
      module = import ../modules/agenix-rekey.nix pkgs.path {
        inherit lib pkgs;
        options = { };
        config.age = {
          secrets = { };
          rekey = { inherit masterIdentities extraEncryptionPubkeys; };
        };
      };
    in
    (builtins.head (lib.flatten (lib.modules.dischargeProperties module.config.assertions))).assertion;
in
assert hasEncryptionTarget identities [ ];
assert hasEncryptionTarget [ ] [ pluginRecipient ];
assert !(hasEncryptionTarget [ ] [ ]);
builtins.deepSeq (map (x: lib.mapAttrs (_: app: app.drvPath) x.apps) appSets) (
  pkgs.runCommand "extra-decryption-args"
    {
      nativeBuildInputs = [ pkgs.python3 ];
      testData = builtins.toJSON {
        inherit extraDecryptionArgs pubkey;
        defaults = commands { };
        extra = commands { inherit extraDecryptionArgs; };
        apps = map (x: {
          # Support the PR base and main, where edit/view share one app.
          program = lib.getExe (x.apps.edit-view or x.apps.edit);
          arguments = lib.optional (x.apps ? edit-view) "edit";
          inherit (x) extra;
        }) appSets;
        plugins =
          map
            (
              package:
              commands {
                agePackage = p: p.${package};
                extraDecryptionArgs = [
                  "-j"
                  "rekeytest"
                ];
                nodes.host.config.age = {
                  secrets = { };
                  rekey = {
                    masterIdentities = [ ];
                    extraEncryptionPubkeys = [ pluginRecipient ];
                    agePlugins = [ plugin ];
                  };
                };
              }
            )
            [
              "age"
              "rage"
            ];
      };
    }
    ''
      python3 ${./extra-decryption-args.py}
      touch "$out"
    ''
)
