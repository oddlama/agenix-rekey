{
  lib,
  options,
  config,
  pkgs,
  ...
}:
with lib; {
  config = let
    rekeyedSecrets = import ../nix/output-derivation.nix pkgs config;
  in
    mkIf (config.rekey.secrets != {}) {
      # Produce a rekeyed age secret for each of the secrets defined in rekey.secrets
      age.secrets = mapAttrs (secretName:
        flip mergeAttrs {
          file = "${rekeyedSecrets.drv}/${secretName}";
        })
      config.rekey.secrets;

      assertions = [
        {
          assertion = config.rekey.masterIdentityPaths != [];
          message = "rekey.masterIdentityPaths must be set.";
        }
      ];

      warnings = let
        hasGoodSuffix = x: strings.hasSuffix ".age" x || strings.hasSuffix ".pub" x;
      in
        optional (!rekeyedSecrets.isBuilt) ''The secrets for host ${config.networking.hostName} have not yet been rekeyed! Be sure to run `nix run ".#rekey"` after changing your secrets!''
        ++ optional (!all hasGoodSuffix config.rekey.masterIdentityPaths) ''
          It seems like at least one of your rekey.masterIdentityPaths contains an
          unencrypted age identity. These files will be copied to the nix store, so
          make sure they don't contain any secret information!

          To silence this warning, encrypt your keys and name them *.pub or *.age.
        '';
    };

  options = {
    rekey.secrets = options.age.secrets;
    rekey.hostPubkey = mkOption {
      type = with types; coercedTo path readFile str;
      description = ''
        The age public key to use as a recipient when rekeying.
        This either has to be the path to an age public key file,
        or the public key itself in string form.

        Make sure to NEVER use a private key here, as it will end
        up in the public nix store!
      '';
      #example = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEyH9Vx7WJZWW+6tnDsF7JuflcxgjhAQHoCWVrjLXQ2U my-host";
      #example = "age159tavn5rcfnq30zge2jfq4yx60uksz8udndp0g3njzhrns67ca5qq3n0tj";
      example = /etc/ssh/ssh_host_ed25519_key.pub;
    };
    rekey.masterIdentityPaths = mkOption {
      type = types.listOf types.path;
      description = ''
        The age identity used to decrypt the secrets stored in the repository, so they can be rekeyed for a specific host.
        This identity will be stored in the nix store, so be sure to use a split-identity (like a yubikey identity, which is public),
        or an encrypted age identity. You can encrypt an age identity using `rage -p -o privkey.age privkey` to protect it in your store.

        All identities given here will be passed to age, which will select one of them for decryption.
      '';
      default = [];
      example = [./secrets/my-yubikey-identity.txt];
    };
    rekey.agePlugins = mkOption {
      type = types.listOf types.package;
      default = [];
      description = ''
        A list of plugins that should be available to rage while rekeying.
        They will be added to the PATH before rage is invoked.
      '';
      example = [pkgs.age-plugin-yubikey];
    };
  };
}
