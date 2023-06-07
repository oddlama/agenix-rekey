nixpkgs: {
  lib,
  options,
  config,
  pkgs,
  ...
}:
with lib; let
  # This pubkey is just binary 0x01 in each byte, so you can be sure there is no known private key for this
  dummyPubkey = "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq";
  isAbsolutePath = x: substring 0 1 x == "/";
  rekeyHostPkgs =
    if config.age.rekey.forceRekeyOnSystem == null
    then pkgs
    else import nixpkgs {system = config.age.rekey.forceRekeyOnSystem;};
  rekeyedSecrets = import ../nix/output-derivation.nix rekeyHostPkgs config;
in {
  config = {
    assertions =
      [
        {
          assertion = config.age.rekey.masterIdentities != [];
          message = "rekey.masterIdentities must be set.";
        }
        {
          assertion = all isAbsolutePath config.age.rekey.masterIdentities;
          message = "All masterIdentities must be referred to by an absolute path, but (${filter isAbsolutePath config.age.rekey.masterIdentities}) is not.";
        }
      ]
      ++ flatten (flip mapAttrsToList config.age.secrets (
        secretName: secretCfg: [
          # {
          #   assertion = config.generate != null -> config.rekeyFile != null;
          #   message = "rekeyFile must be set when using secret generation.";
          # }
        ]
      ));

    warnings = let
      hasGoodSuffix = x: (strings.hasSuffix ".age" x || strings.hasSuffix ".pub" x);
    in
      # optional (!rekeyedSecrets.isBuilt) ''The secrets for host ${config.networking.hostName} have not yet been rekeyed! Be sure to run `nix run .#rekey` after changing your secrets!''
      optional (!all hasGoodSuffix config.age.rekey.masterIdentities) ''
        At least one of your rekey.masterIdentities references an unencrypted age identity in your nix store!
        ${concatMapStrings (x: "  - ${x}\n") (filter hasGoodSuffix config.age.rekey.masterIdentities)}

        These files have already been copied to the nix store, and are now publicly readable!
        Please make sure they don't contain any secret information or delete them now.

        To silence this warning, you may:
          - Use a split-identity ending in `.pub`, where the private part is not contained (a yubikey identity)
          - Use an absolute path to your key outside of the nix store ("/home/myuser/age-master-key")
          - Or encrypt your age identity and use the extension `.age`. You can encrypt an age identity
            using `rage -p -o privkey.age privkey` which protects it in your store.
      ''
      ++ optional (config.age.rekey.hostPubkey == dummyPubkey) ''
        You have not yet specified rekey.hostPubkey for your host ${config.networking.hostName}.
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
        #assertions = flip mapAttrsToList config.rekey.secrets (secretName: secretCfg:
        #  let
        #    secretOpts = (options.rekey.secrets.type.functor.wrapped.getSubOptions secretCfg);
        #  in
        #    {
        #      assertion = secretCfg.rekeyFile != null -> length secretOpts.file.definitions == 1;
        #      message = ''
        #        `rekeyFile` is used for this secret, but there are conflicting `file` definitions:
        #        ${showOptionWithDefLocs secretOpts.file}'';
        #    };

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
      type = types.attrsOf (types.submodule ({
        config,
        name,
        ...
      }: {
        options = {
          rekeyFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = mdDoc ''
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
        };
        config = {
          # Produce a rekeyed age secret
          file = mkIf (config.rekeyFile != null) "${rekeyedSecrets.drv}/${name}.age";
        };
      }));
    };

    rekey = {
      forceRekeyOnSystem = mkOption {
        type = types.nullOr types.str;
        description = mdDoc ''
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
        description = mdDoc ''
          The age public key to use as a recipient when rekeying. This either has to be the
          path to an age public key file, or the public key itself in string form.

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
        example = "/etc/ssh/ssh_host_ed25519_key.pub";
      };
      masterIdentities = mkOption {
        type = with types; listOf (coercedTo path toString str);
        description = mdDoc ''
          The list of age identities that will be presented to `rage` when decrypting the stored secrets
          to rekey them for your host(s). If multiple identities are given, they will be tried in-order.

          The recommended options are:

          - Use a split-identity ending in `.pub`, where the private part is not contained (a yubikey identity)
          - Use an absolute path to your key outside of the nix store ("/home/myuser/age-master-key")
          - Or encrypt your age identity and use the extension `.age`. You can encrypt an age identity
            using `rage -p -o privkey.age privkey` which protects it in your store.

          If you are using YubiKeys, you can specify multiple split-identities here and use them interchangeably.
          You will have the option to skip any YubiKeys that are not available to you in that moment.

          Be careful when using paths here, as they will be copied to the nix store. Using
          split-identities is fine, but if you are using plain age identities, make sure that they
          are password protected.
        '';
        default = [];
        example = [./secrets/my-public-yubikey-identity.txt];
      };
      extraEncryptionPubkeys = mkOption {
        type = with types; listOf (coercedTo path toString str);
        description = mdDoc ''
          When using `nix run .#edit-secret FILE`, the file will be encrypted for all identities in
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
        description = mdDoc ''
          A list of plugins that should be available to rage while rekeying.
          They will be added to the PATH with lowest-priority before rage is invoked,
          meaning if you have the plugin installed on your system, that one is preferred
          in an effort to not break complex setups (e.g. WSL passthrough).
        '';
      };
    };
  };
}
