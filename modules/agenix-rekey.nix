nixpkgs: {
  lib,
  config,
  pkgs,
  ...
}: let
  inherit
    (lib)
    all
    assertMsg
    concatMapStrings
    filter
    flatten
    flip
    hasAttr
    hasPrefix
    hasSuffix
    isAttrs
    isPath
    isString
    literalExpression
    mapAttrs
    mapAttrs'
    mapAttrsToList
    mkIf
    mkOption
    mkRenamedOptionModule
    nameValuePair
    optional
    readFile
    showOptionWithDefLocs
    substring
    types
    ;

  target = (import ../nix/target-name.nix) {inherit pkgs config;};
  # This pubkey is just binary 0x01 in each byte, so you can be sure there is no known private key for this
  dummyPubkey = "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq";
  isAbsolutePath = x: substring 0 1 x == "/";
  rekeyHostPkgs =
    if config.age.rekey.forceRekeyOnSystem == null
    then pkgs
    else import nixpkgs {system = config.age.rekey.forceRekeyOnSystem;};

  rekeyedSecrets = import ../nix/output-derivation.nix {
    appHostPkgs = rekeyHostPkgs;
    hostConfig = config;
  };

  rekeyedLocalSecret = secret: let
    pubkeyHash = builtins.hashString "sha256" config.age.rekey.hostPubkey;
    identHash = builtins.substring 0 32 (
      builtins.hashString "sha256"
      (pubkeyHash + builtins.hashFile "sha256" secret.rekeyFile)
    );

    generateHint =
      if secret.generator != null
      then "Did you run `[32magenix generate[m` to generate it and have you added it to git?"
      else "Have you added it to git?";

    # Use builtins.path to make sure that we have a standalone copy of the subdirectory in the store.
    # This is important to ensure that the path only changes if there are acutal changes to this
    # directory. If we were still using userFlake.outPath + "/secrets/[...]" or something similar,
    # then the path would change on each subsequent build because the flake path changes.
    rekeyedPath = builtins.path {path = config.age.rekey.localStorageDir;} + "/${identHash}-${secret.name}.age";
  in
    assert assertMsg (secret.rekeyFile != null -> builtins.pathExists secret.rekeyFile) ''
      [1;31mhost ${target}: age.secrets.${secret.id}.rekeyFile ([33m${toString secret.rekeyFile}[m[1;31m) doesn't exist.[0m ${generateHint}
    '';
    assert assertMsg (builtins.pathExists rekeyedPath) ''
      [1;31mhost ${target}: Rekeyed secret for age.secrets.${secret.id} not found, please run `[33magenix rekey -a[1;31m` again and make sure to add the results to git.[m
      [90m  rekeyed secret path: ${toString rekeyedPath}[m
    '';
    # Return rekeyed path after checking that both the rekeyFile (original) and rekeyed version exist
      rekeyedPath;

  generatorType = types.submodule (submod: {
    options = {
      dependencies = mkOption {
        type = types.listOf types.unspecified;
        example = literalExpression ''[ config.age.secrets.basicAuthPw1 nixosConfigurations.machine2.config.age.secrets.basicAuthPw ]'';
        default = [];
        description = ''
          Other secrets on which this secret depends. This guarantees that in the final
          `agenix generate` script, all dependencies will be generated before
          this secret is generated, allowing you use their outputs via the passed `decrypt` function.

          The given dependencies will be passed to the defined `script` via the `deps` parameter,
          which will be a list of their true source locations (`rekeyFile`) in no particular order.

          This should refer only to secret definitions from `config.age.secrets` that
          have a generator. This is useful if you want to create derived secrets,
          such as generating a .htpasswd file from several basic auth passwords.

          You may refer to age secrets of other nixos hosts as long as all hosts
          are rekeyed via the same flake.
        '';
      };

      script = mkOption {
        type = types.either types.str (types.functionTo types.str);
        example = literalExpression ''
          {
            name,    # The name of the secret to be generated, as defined in `age.secrets.<name>`
            secret,  # The definition of the secret to be generated
            lib,     # Convenience access to the nixpkgs library
            pkgs,    # The package set for the _host that is running the generation script_.
                     #   Don't use any other packgage set!
            file,    # The actual path to the .age file that will be written after
                     #   this function returns and the content is encrypted.
                     #   Useful to write additional information to adjacent files.
            deps,    # The list of all secret files from our `dependencies`.
                     #   Each entry is a set of `{ name, host, file }`, corresponding to
                     #   the secret `nixosConfigurations.''${host}.age.secrets.''${name}`.
                     #   `file` is the true source location of the secret's `rekeyFile`.
                     #   You can extract the plaintext with `''${decrypt} ''${escapeShellArg dep.file}`.
            decrypt, # The base rage command that can decrypt secrets to stdout by
                     #   using the defined `masterIdentities`.
            ...      # For future/unused arguments
          }: '''
            priv=$(''${pkgs.wireguard-tools}/bin/wg genkey)
            ''${pkgs.wireguard-tools}/bin/wg pubkey <<< "$priv" > ''${lib.escapeShellArg (lib.removeSuffix ".age" file + ".pub")}
            echo "$priv"
          '''
        '';
        description = ''
          This must either be the name of a globally defined generator, or
          a function that evaluates to a script. The resulting script will be
          added to the internal, global generation script verbatim and runs
          outside of any sandbox. Refer to `age.generators` for example usage.

          This allows you to create/overwrite adjacent files if neccessary, for example
          when you also want to store the public key for a generated private key.
          Refer to the example for a description of the arguments. The resulting
          secret should be written to stdout and any info or errors to stderr.

          Note that the script is run with `set -euo pipefail` conditions as the
          normal user that runs `agenix generate`.
        '';
      };

      _script = mkOption {
        type = types.nullOr types.unspecified;
        readOnly = true;
        internal = true;
        description = "The effective script definition.";
        default =
          if isString submod.config.script
          then config.age.generators.${submod.config.script}
          else submod.config.script;
      };

      tags = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["wireguard"];
        description = ''
          Optional list of tags that may be used to refer to secrets that use this generator.
          Useful to regenerate all secrets matching a specific tag using `agenix generate -f -t wireguard`.
        '';
      };
    };
  });

  masterIdentityPaths = map (x: x.identity) config.age.rekey.masterIdentities;
in {
  config = {
    assertions =
      [
        {
          assertion = config.age.rekey.masterIdentities != [];
          message = "rekey.masterIdentities must be set.";
        }
        {
          assertion = all isAbsolutePath masterIdentityPaths;
          message = "All masterIdentities must be referred to by an absolute path, but (${filter isAbsolutePath masterIdentityPaths}) is not.";
        }
      ]
      ++ flatten (flip mapAttrsToList config.age.secrets
        (secretName: secretCfg: [
          {
            assertion = isString secretCfg.generator -> hasAttr secretCfg.generator config.age.generators;
            message = "age.secrets.${secretName}: generator '`${secretCfg.generator}`' is not defined in `age.generators`.";
          }
          {
            assertion = secretCfg.generator != null -> secretCfg.rekeyFile != null;
            message = "age.secrets.${secretName}: `rekeyFile` must be set when using a generator.";
          }
        ]));

    warnings = let
      hasGoodSuffix = x: (hasPrefix builtins.storeDir x) -> (hasSuffix ".age" x || hasSuffix ".pub" x || hasSuffix ".hmac" x);
    in
      optional (!all hasGoodSuffix masterIdentityPaths) ''
        At least one of your rekey.masterIdentities references an unencrypted age identity in your nix store!
        ${concatMapStrings (x: "  - ${x}\n") (filter hasGoodSuffix masterIdentityPaths)}

        These files have already been copied to the nix store, and are now publicly readable!
        Please make sure they don't contain any secret information or delete them now.

        To silence this warning, you may:
          - Use a split-identity ending in `.pub` or `.hmac`, where the private part is not contained (a yubikey identity)
          - Use an absolute path to your key outside of the nix store ("/home/myuser/age-master-key")
          - Or encrypt your age identity and use the extension `.age`. You can encrypt an age identity
            using `rage -p -o privkey.age privkey` which protects it in your store.
      ''
      ++ optional (config.age.rekey.hostPubkey == dummyPubkey) ''
        You have not yet specified rekey.hostPubkey for your host ${target}.
        All secrets for this host will be rekeyed with a dummy key, resulting in an activation failure.

        This is intentional so you can initially deploy your system to read the actual pubkey.
        Once you have the pubkey, set rekey.hostPubkey to the content or a file containing the pubkey.
      '';
  };

  imports = [
    (mkRenamedOptionModule ["rekey" "forceRekeyOnSystem"] ["age" "rekey" "forceRekeyOnSystem"])
    (mkRenamedOptionModule ["rekey" "hostPubkey"] ["age" "rekey" "hostPubkey"])
    (mkRenamedOptionModule ["rekey" "masterIdentities"] ["age" "rekey" "masterIdentities"])
    (mkRenamedOptionModule ["rekey" "extraEncryptionPubkeys"] ["age" "rekey" "extraEncryptionPubkeys"])
    (mkRenamedOptionModule ["rekey" "agePlugins"] ["age" "rekey" "agePlugins"])
    ({
      config,
      options,
      ...
    }: {
      options.rekey.secrets = options.age.secrets // {visible = false;};
      config = {
        warnings = optional (config.rekey.secrets != {}) ''
          The option `rekey.secrets` has been integrated into `age.secrets`.
          Generally, the new option specification is the compatible with the old one,
          but all usages of `rekey.secrets.<name>.file` have to be replaced with
          `age.secrets.<name>.rekeyFile`. Found ocurrences in:
          ${showOptionWithDefLocs options.rekey.secrets}
        '';

        age.secrets =
          mapAttrs
          (_: secret:
            mapAttrs' (n:
              nameValuePair (
                if n == "file"
                then "rekeyFile"
                else n
              ))
            secret)
          config.rekey.secrets;
      };
    })
  ];

  options.age = {
    # Extend age.secrets with new options
    secrets = mkOption {
      type = types.attrsOf (types.submodule (submod: {
        options = {
          id = mkOption {
            type = types.str;
            default = submod.config._module.args.name;
            readOnly = true;
            description = "The true identifier of this secret as used in `age.secrets`.";
          };

          intermediary = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Whether the secret is only required as an intermediary/repository
              secret and should not be uploaded and decrypted on the host.
            '';
          };

          rekeyFile = mkOption {
            type = types.nullOr types.path;
            default =
              if config.age.rekey.generatedSecretsDir != null
              then config.age.rekey.generatedSecretsDir + "/${submod.config.id}.age"
              else null;
            example = literalExpression "./secrets/password.age";
            description = ''
              The path to the encrypted .age file for this secret. The file must
              be encrypted with one of the given `age.rekey.masterIdentities` and not with
              a host-specific key.

              This secret will automatically be rekeyed for hosts that use it, and the resulting
              host-specific .age file will be set as actual `file` attribute. So naturally this
              is mutually exclusive with specifying `file` directly.

              If you want to avoid having a `secrets.nix` file and only use rekeyed secrets,
              you should always use this option instead of `file`.
            '';
          };

          generator = mkOption {
            type = types.nullOr generatorType;
            default = null;
            example = {script = "passphrase";};
            description = "If defined, this generator will be used to bootstrap this secret's when it doesn't exist.";
          };
        };
        config = {
          # Produce a rekeyed age secret
          file = mkIf (submod.config.rekeyFile != null) (
            if config.age.rekey.storageMode == "derivation"
            then "${rekeyedSecrets}/${submod.config.name}.age"
            else rekeyedLocalSecret config.age.secrets.${submod.config.id}
          );
        };
      }));
    };

    generators = mkOption {
      type = types.attrsOf (types.functionTo types.str);
      example = ''
        {
          alnum = {pkgs, ...}: "''${pkgs.pwgen}/bin/pwgen -s 48 1";

          # when using this, add some dependencies:
          # age.secrets.<name>.generator = {
          #   script = "aggregateHtpasswd";
          #   dependencies = [ config.age.secrets.basicAuthPw1 config.age.secrets.basicAuthPw2 ];
          # };
          aggregateHtpasswd = { pkgs, lib, decrypt, deps, ... }:
            lib.flip lib.concatMapStrings deps ({ name, host, file }: '''
              echo "Aggregating "''${lib.escapeShellArg host}:''${lib.escapeShellArg name} >&2
              # Decrypt the dependency containing the cleartext password,
              # and run it through htpasswd to generate a bcrypt hash
              ''${decrypt} ''${lib.escapeShellArg file} \
                | ''${pkgs.apacheHttpd}/bin/htpasswd -niBC 10 ''${lib.escapeShellArg host}
            ''');
          };
        }
      '';
      description = ''
        Allows defining reusable secret generator scripts. By default these generators are provided:

        - `alnum`: Generates an alphanumeric string of length 48
        - `base64`: Generates a base64 string of 32-byte random (length 44)
        - `hex`: Generates a hex string of 24-byte random (length 48)
        - `passphrase`: Generates a 6-word passphrase delimited by spaces
        - `dhparams`: Generates 4096-bit dhparams
        - `ssh-ed25519`: Generates a ssh-ed25519 private key
      '';
    };

    rekey = {
      generatedSecretsDir = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          The path where all generated secrets should be stored by default.
          If set, this automatically sets `age.secrets.<name>.rekeyFile` to a default
          value in this directory, for any secret that defines a generator.
        '';
      };

      storageMode = mkOption {
        type = types.enum ["derivation" "local"];
        default = abort ''
          !!!
          agenix-rekey now supports storing rekeyed secrets locally instead of as a derivation.
          You should explicitly specify the desired storage mode for each host!

          Got no time right now? Set this to keep the old behavior:

              age.rekey.storageMode = "derivation";

          If you have just installed agenix-rekey, chose "local" and ignore this message:

              # Choose "local" (new behavior) or "derivation" (old behavior).
              age.rekey.storageMode = "local";
              # Choose a directory to store the rekeyed secrets for this host.
              # This cannot be shared with other hosts. Please refer to this path
              # from your flake's root directory and not by a direct path literal like ./secrets
              age.rekey.localStorageDir = ./. + "/secrets/rekeyed/${target}";

          The new local storage mode is more pure and simpler. It allows building your system without access to the
          (yubi)key, for example in a CI environment. Depending on your threat-model it might be considered less secure,
          especially when your repo is public and one your host-keys leaks. Visit the README (https://github.com/oddlama/agenix-rekey)
          and search check the section on 'Storage Modes' for more information.

          To keep the old behavior, select "derivation". This message will be removed end of 2024 so we can choose an upstream default.
        '';
        description = ''
          You have the choice between two storage modes for your rekeyed secrets, which
          are fundamentally different from each other. You can freely switch between them at any time.

          Option one is to store the rekeyed secrets locally in your repository (`local`), option two is to
          transparently store them in a derivation that will be created automatically (`derivation`).
          If in doubt use `local` which is more flexible and pure, but keep in mind that `derivation`
          can be more secure for certain cases. It uses more "magic" to hide some details and might be
          simpler to use if you only build on one host and don't care about remote building / CI.
          The choice depends on your organizational preferences and threat model.

          **derivation**: Previously this was the default mode. All rekeyed secrets for each host will
            be collected in a derivation which copies them to the nix store when it is built using `agenix rekey`.

            Pro: The entire process is stateless and rekeyed secrets are never committed to your repository.
            Con: You cannot easily build your host from a CI/any host that hasn't access to your (yubi)key
                 except by manually uploading the derivations to the CI after rekeying.

          **local**: All rekeyed secrets will be saved to a local folder in your flake when running `agenix rekey`.
            Agenix will use these local files directly, without requiring any extra derivations. This is the simpler
            approach and has less edge-cases.

            Pro: System building stays pure, no need for sandbox shenanigans. -> System can be built without access to the (yubi)key.
            Con: If your repository is public and one of your hosts is compromised, an attacker may decrypt
                 any secret that was ever encrypted for that host. This includes secrets that are in the git history.
        '';
      };

      localStorageDir = mkOption {
        type = types.path;
        example = literalExpression ''./. /* <- flake root */ + "/secrets/rekeyed/myhost" /* separate folder for each host */'';
        description = ''
          Only used when `storageMode = "local"`.

          The local storage directory for rekeyed secrets. MUST be a path inside of your repository,
          and it MUST be constructed by concatenating to the root directory of your flake. Follow
          the example.
        '';
      };

      derivation = mkOption {
        type = types.package;
        default = assert assertMsg (config.age.rekey.storageMode == "derivation") ''Accessing the secrets derivation is only possible when `storageMode` is set to `"derivation"`''; rekeyedSecrets;
        readOnly = true;
        description = ''
          Only used when `storageMode = "derivation"`.

          The derivation that contains the rekeyed secrets.
          Cannot be built directly, use `agenix rekey` instead.
        '';
      };

      cacheDir = mkOption {
        type = types.str;
        default = "/tmp/agenix-rekey.\"$UID\"";
        example = "/var/tmp/agenix-rekey.\"$UID\"";
        description = ''
          Only used when `storageMode = "derivation"`.

          This is the directory where we store the rekeyed secrets
          so that they can be found later by the derivation builder.

          Must be a bash expression that expands to the directory to use
          as a cache. By default the cache is kept in /tmp, but you can
          change it (see example) to persist the cache across reboots.
          The directory must be readable by the nix build users. Make
          sure to use corret quoting, this _must_ be a bash expression
          resulting in a single string.

          The actual secrets will be stored in the directory based on their input
          content hash (derived from host pubkey and file content hash), and stored
          as `''${cacheDir}/secrets/<ident-sha256>-<filename>`. This allows us to
          reuse already existing rekeyed secrets when rekeying again, while providing
          a deterministic path for each secret.
        '';
      };

      forceRekeyOnSystem = mkOption {
        type = types.nullOr types.str;
        description = ''
          Only used when `storageMode = "derivation"`.

          If set, this will force that all secrets are rekeyed on a system of the given architecture.
          This is important if you have several hosts with different architectures, since you usually
          don't want to build the derivation containing the rekeyed secrets on a random remote host.

          The problem is that each derivation will always depend on at least one specific architecture
          (often it's bash), since it requires a builder to create it. Usually the builder will use the
          architecture for which the package is built, which makes sense. Since it is part of the derivation
          inputs, we have to know it in advance to predict where the output will be. If you have multiple
          architectures, then we'd have multiple candidate derivations for the rekeyed secrets, but we want
          a single predictable derivation.

          If you would try to deploy an aarch64-linux system, but are on x86_64-linux without binary
          emulation, then nix would have to build the rekeyed secrets using a remote builder (since the
          derivation then requires aarch64-linux bash). This option will override the pkgs set passed to
          the derivation such that it will use a builder of the specified architecture instead. This way
          you can force it to always require a x86_64-linux bash, thus allowing your local system to build it.

          The "automatic" and nice way would be to set this to builtins.currentSystem, but that would
          also be impure, so unfortunately you have to hardcode this option.
        '';
        default = null;
        example = "x86_64-linux";
      };
      hostPubkey = mkOption {
        type = with types;
          coercedTo path (x:
            if isPath x
            then readFile x
            else x)
          str;
        description = ''
          The age public key to use as a recipient when rekeying. This either has to be the
          path to an age public key file, or the public key itself in string form.
          HINT: If you want to use a path, make sure to use an actual nix path, so for example
          `./host.pub`, otherwise it will be interpreted as the content and cause errors.
          Alternatively you can use `readFile "/path/to/host.pub"` yourself.

          If you are managing a single host only, you can use `"/etc/ssh/ssh_host_ed25519_key.pub"`
          here to allow the rekey app to directly read your pubkey from your system.

          If you are managing multiple hosts, it's recommended to either store a copy of each
          host's pubkey in your flake and use refer to those here `./secrets/host1-pubkey.pub`,
          or directly set the host's pubkey here by specifying `"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI..."`.

          Make sure to NEVER use a private key here, as it will end up in the public nix store!
        '';
        default = dummyPubkey;
        #example = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI.....";
        #example = "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq";
        example = literalExpression "./secrets/host1.pub";
        #example = "/etc/ssh/ssh_host_ed25519_key.pub";
      };
      masterIdentities = mkOption {
        type = with types; let
          identityPathType = coercedTo path toString str;
        in
          listOf (
            # By coercing the old identityPathType into a canonical submodule of the form
            # ```
            # {
            #   identity = <identityPath>;
            #   pubkey = ...;
            # }
            # ```
            # we don't have to worry about it at a later stage.
            coercedTo
            identityPathType
            (p:
              if isAttrs p
              then p
              else {identity = p;})
            (submodule {
              options = {
                identity = mkOption {type = identityPathType;};
                pubkey = mkOption {
                  type = nullOr (coercedTo path (x:
                    if isPath x
                    then readFile x
                    else x)
                  str);
                  default = null;
                };
              };
            })
          );
        description = ''
          The list of age identities that will be presented to `rage` when decrypting the stored secrets
          to rekey them for your host(s). If multiple identities are given, they will be tried in-order.

          The recommended options are:

          - Use a split-identity ending in `.pub`, where the private part is not contained (a yubikey identity)
          - Use an absolute path to your key outside of the nix store ("/home/myuser/age-master-key")
          - Or encrypt your age identity and use the extension `.age`. You can encrypt an age identity
            using `rage -p -o privkey.age privkey` which protects it in your store.

          If you are using YubiKeys, you can specify multiple split-identities here and use them interchangeably.
          You will have the option to skip any YubiKeys that are not available to you in that moment.

          To prevent issues with master keys that may be sometimes unavailable during encryption,
          an alternate syntax is possible:

          ```nix
          age.rekey.masterIdentities = [
            {
              # This has the same type as the other ways to specify an identity.
              identity = ./password-encrypted-identity.pub;
              # Optional; This has the same type as `age.rekey.hostPubkey`
              # and allows explicit association of a pubkey with the identity.
              pubkey = "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq";
            }
          ];
          ```

          If a pubkey is explicitly specified, it will be used
          in place of the associated identity during encryption. This prevents additional prompts
          in the case of a password encrypted key file or prompts for identities that can only be accessed
          by certain people in a multi-user scenario. For Yubikey identities the pubkey can be automatically
          extracted from the identity file, if there is a comment of the form `Recipient: age1yubikey1<key>`
          present in the identity file.
          This should be the case for identity files generated by the `age-plugin-yubikey` CLI.
          See the description of [pull request #28](https://github.com/oddlama/agenix-rekey/pull/28)
          for more information on the exact criteria for automatic pubkey extraction.

          For setups where the primary identity may change depending on the situation, e.g. in a multi-user setup,
          where each person only has access to their own personal Yubikey, check out the
          `AGENIX_REKEY_PRIMARY_IDENTITY` environment variable.

          Be careful when using paths here, as they will be copied to the nix store. Using
          split-identities is fine, but if you are using plain age identities, make sure that they
          are password protected.
        '';
        default = [];
        example = [
          ./secrets/my-public-yubikey-identity.txt
          {
            identity = ./password-encrypted-identity.pub;
            pubkey = "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq";
          }
        ];
      };
      extraEncryptionPubkeys = mkOption {
        type = with types; listOf (coercedTo path toString str);
        description = ''
          When using `agenix edit FILE`, the file will be encrypted for all identities in
          rekey.masterIdentities by default. Here you can specify an extra set of pubkeys for which
          all secrets should also be encrypted. This is useful in case you want to have a backup indentity
          that must be able to decrypt all secrets but should not be used when attempting regular decryption.

          If the coerced string is an absolute path, it will be used as if it was a recipient file.
          Otherwise, the string will be interpreted as a public key.
        '';
        default = [];
        example = [./backup-key.pub "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq"];
      };
      agePlugins = mkOption {
        type = types.listOf types.package;
        default = [rekeyHostPkgs.age-plugin-yubikey];
        description = ''
          A list of plugins that should be available to rage while rekeying.
          They will be added to the PATH with lowest-priority before rage is invoked,
          meaning if you have the plugin installed on your system, that one is preferred
          in an effort to not break complex setups (e.g. WSL passthrough).
        '';
      };
    };
  };

  config.age.generators = {
    alnum = {pkgs, ...}: "${pkgs.pwgen}/bin/pwgen -s 48 1";
    base64 = {pkgs, ...}: "${pkgs.openssl}/bin/openssl rand -base64 32";
    hex = {pkgs, ...}: "${pkgs.openssl}/bin/openssl rand -hex 24";
    passphrase = {pkgs, ...}: "${pkgs.xkcdpass}/bin/xkcdpass --numwords=6 --delimiter=' '";
    dhparams = {pkgs, ...}: "${pkgs.openssl}/bin/openssl dhparam 4096";
    ssh-ed25519 = {
      lib,
      name,
      pkgs,
      ...
    }: ''(exec 3>&1; ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C ${lib.escapeShellArg "${target}:${name}"} -f /proc/self/fd/3 <<<y >/dev/null 2>&1; true)'';
  };
}
