# This is the derivation that copies the rekeyed secrets into the nix-store.
# We use mkDerivation here to building this derivatoin on any system while
# allowing the result to be system-agnostic.
hostPkgs: hostConfig:
with hostPkgs.lib; let
  pubkeyHash = builtins.hashString "sha1" hostConfig.rekey.hostPubkey;
in
  hostPkgs.stdenv.mkDerivation rec {
    name = "agenix-rekey-host-secrets";
    description = "Rekeyed secrets for host ${hostConfig.networking.hostName} (${pubkeyHash})";

    # No special inputs are necessary.
    dontUnpack = true;
    dontPatch = true;
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;
    dontCopyDist = true;

    # Variables that may be interesting for consumers of this derivation,
    # which should be accessible without requiring the derivation to be built.
    passthru = {
      # The directory where rekeyed secrets are temporarily stored. Since
      tmpSecretsDir = "/tmp/nix-rekey/${pubkeyHash}";
      # A predictable unique string that depends on all inputs. Used to
      # ensure that the content in /tmp is correctly preseverved between invocations
      # of rekeying and deployment.
      personality = builtins.baseNameOf (removeSuffix ".drv" drvPath);
      # Indicates whether the derivation has already been built and is available in the store.
      # Using drvPath doesn't force evaluation, which allows this to be used to show warning
      # messages in case the derivation is not built before deploying
      isBuilt = pathExists (removeSuffix ".drv" drvPath);
    };

    # All used secrets are inputs to this derivation, but are completely system-agnostic.
    # Technically we don't even access them here, but the derivation still has to be rebuilt if the secrets change.
    #
    # The pubkey hash for this host is also required as an additional input to
    # force a derivation rebuild if it changes in the future.
    nativeBuildInputs = mapAttrsToList (_: x: x.file) hostConfig.rekey.secrets ++ [pubkeyHash];

    # When this derivation is built, the rekeyed secrets must be copied
    # into the derivation output, so they are stored permanently and become accessible
    # to the host via the predictable output path for this derivation
    installPhase = ''
      mkdir -p "$out"
      # Ensure that the rekey command has already been executed.
      test -e "/${tmpSecretsDir}/personality" \
        || { echo "[1;31mNo rekeyed secrets were found, please execute \`nix run \".#rekey\"\` first.[m" >&2; exit 1; }
      # Ensure that the contents of the /tmp directory actually belong to this derivation
      [ $(cat "/${tmpSecretsDir}/personality") = $(basename .) ] \
        || { echo "[1;31mThe existing rekeyed secrets in /tmp are out-of-date. Please re-run \`nix run \".#rekey\"\`.[m" >&2; exit 1; }
      cp -r "${tmpSecretsDir}/." "$out"
    '';
  }
