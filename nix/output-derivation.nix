pkgs: config:
with pkgs.lib; let
  pubkeyHash = builtins.hashString "sha1" config.rekey.hostPubkey;
in rec {
  # The directory where rekeyed secrets are temporarily stored. Since
  tmpSecretsDir = "/tmp/nix-rekey/${pubkeyHash}";

  # A predictable unique string that depends on all inputs. Used to
  # ensure that the content in /tmp is correctly preseverved between invocations
  # of rekeying and deployment.
  personality = builtins.baseNameOf (removeSuffix ".drv" drv.drvPath);
  # Indicates whether the derivation has already been built and is available in the store.
  # Using drvPath doesn't force evaluation, which allows this to be used to show warning
  # messages in case the derivation is not built before deploying
  isBuilt = pathExists (removeSuffix ".drv" drv.drvPath);
  # This is the derivation that copies the rekeyed secrets into the nix-store.
  drv = derivation rec {
    inherit (pkgs) system;
    name = "rekeyed-host-secrets";
    description = "Rekeyed secrets for host ${config.networking.hostName} (${pubkeyHash})";

    # All used secrets are inputs to this derivation. Technically we don't access
    # them here, but the derivation still has to be rebuilt if the secrets change.
    secrets = mapAttrsToList (_: x: x.file) config.rekey.secrets;
    # The pubkey hash for this host is required as an additional input to
    # force a derivation rebuild if the pubkey changes
    inherit pubkeyHash;

    # When this derivation is built, the rekeyed secrets must be copied
    # into the derivation output, so they are stored permanently and become accessible
    # to the host via the predictable output path for this derivation
    builder = pkgs.writeShellScript "copy-rekeyed-secrets" ''
      ${pkgs.coreutils}/bin/mkdir -p "$out"
      # Ensure that the contents of the /tmp directory actually belong to this derivation
      [ $(${pkgs.coreutils}/bin/cat "/${tmpSecretsDir}/personality") = $(${pkgs.coreutils}/bin/basename .) ] \
        || { echo "The existing rekeyed secrets in /tmp are out-of-date. Please re-run the rekey command." >&2; exit 1; }
      ${pkgs.coreutils}/bin/cp -r "${tmpSecretsDir}/." "$out"
    '';
  };
}
