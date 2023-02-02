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
    # This pubkey is just binary 0x01 in each byte, so you can be sure there is no known private key for this
    dummyPubkey = "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq";
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
          assertion = config.rekey.masterIdentities != [];
          message = "rekey.masterIdentities must be set.";
        }
      ];

      warnings = let
        hasGoodSuffix = x: (strings.hasSuffix ".age" x || strings.hasSuffix ".pub" x);
      in
        optional (!rekeyedSecrets.isBuilt) ''The secrets for host ${config.networking.hostName} have not yet been rekeyed! Be sure to run `nix run ".#rekey"` after changing your secrets!''
        ++ optional (!all hasGoodSuffix config.rekey.masterIdentities) ''
          At least one of your rekey.masterIdentities references an unencrypted age identity in your nix store!
          ${concatMapStrings (x: "  - ${x}\n") (filter hasGoodSuffix config.rekey.masterIdentities)}

          These files have already been copied to the nix store, and are now publicly readable!
          Please make sure they don't contain any secret information or delete them now.

          To silence this warning, you may:
            - Use a split-identity ending in `.pub`, where the private part is not contained (a yubikey identity)
            - Use an absolute path to your key outside of the nix store ("/home/myuser/age-master-key")
            - Or encrypt your age identity and use the extension `.age`. You can encrypt an age identity
              using `rage -p -o privkey.age privkey` which protects it in your store.
        ''
        ++ optional (config.rekey.hostPubkey == dummyPubkey) ''
          You have not yet specified rekey.hostPubkey for your host ${config.networking.hostName}.
          All secrets for this host will be rekeyed with a dummy key, resulting in an activation failure.

          This is intentional so you can initially deploy your system to read the actual pubkey.
          Once you have the pubkey, set rekey.hostPubkey to the content or a file containing the pubkey.
        '';
    };

  options = {
    rekey.secrets = options.age.secrets;
    rekey.hostPubkey = mkOption {
      type = with types; coercedTo path readFile str;
      description = ''
        The age public key to use as a recipient when rekeying. This either has to be the
        path to an age public key file, or the public key itself in string form.

        Make sure to NEVER use a private key here, as it will end up in the public nix store!
      '';
      default = dummyPubkey;
      #example = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI.....";
      #example = "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq";
      example = /etc/ssh/ssh_host_ed25519_key.pub;
    };
    rekey.masterIdentities = mkOption {
      type = with types; coercedTo str toString path;
      description = ''
        The age identity used to decrypt your secrets. Be careful when using paths here,
        as they will be copied to the nix store. The recommended options are:

        - Use a split-identity ending in `.pub`, where the private part is not contained (a yubikey identity)
        - Use an absolute path to your key outside of the nix store ("/home/myuser/age-master-key")
        - Or encrypt your age identity and use the extension `.age`. You can encrypt an age identity
          using `rage -p -o privkey.age privkey` which protects it in your store.

        All identities given here will be passed to age, which will consider them for decryption in this order.
      '';
      default = [];
      example = [./secrets/my-public-yubikey-identity.txt];
    };
    rekey.agePlugins = mkOption {
      type = types.listOf types.package;
      default = [pkgs.age-plugin-yubikey];
      description = ''
        A list of plugins that should be available to rage while rekeying.
        They will be added to the PATH before rage is invoked.
      '';
    };
  };
}
