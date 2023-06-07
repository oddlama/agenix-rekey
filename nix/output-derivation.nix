appHostPkgs: hostConfig:
with appHostPkgs.lib; let
  # The hash of the pubkey will be used to enforce a rebuilt when the pubkey changes.
  pubkeyHash = builtins.hashString "sha1" hostConfig.age.rekey.hostPubkey;
  # A predictable unique string that depends on all inputs. Used to generate
  # a unique location in /tmp which can be preseverved between invocations
  # of rekeying and deployment. We explicitly ignore the original location of the file,
  # as only it's id and content are relevant.
  personality = builtins.hashString "sha512" (toString ([pubkeyHash]
    ++ mapAttrsToList (n: v: n + ":" + builtins.hashFile "sha512" v.rekeyFile)
    (filterAttrs (_: v: v.rekeyFile != null) hostConfig.age.secrets)));
  # Shortened personality truncated to 32 characters
  shortPersonality = builtins.substring 0 32 personality;
in rec {
  # The directory where rekeyed secrets are temporarily stored. Since
  tmpSecretsDir = "/tmp/agenix-rekey/${shortPersonality}";

  # FIXME: This would be broken. drv.drvPath does not always equal drv.outPath + ".drv".
  # Indicates whether the derivation has already been built and is available in the store.
  # Using drvPath doesn't force evaluation, which allows this to be used to show warning
  # messages in case the derivation is not built before deploying
  #isBuilt = pathExists (removeSuffix ".drv" drv.drvPath);

  # This is the derivation that copies the rekeyed secrets into the nix-store.
  # We use mkDerivation here to building this derivatoin on any system while
  # allowing the result to be system-agnostic.
  drv = appHostPkgs.stdenv.mkDerivation {
    name = "agenix-rekey-host-secrets";
    description = "Rekeyed secrets for host ${hostConfig.networking.hostName} (${shortPersonality})";

    # No special inputs are necessary.
    dontUnpack = true;
    dontPatch = true;
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;
    dontCopyDist = true;

    # Enforce a rebuild if any input changes.
    inherit personality;

    # When this derivation is built, the rekeyed secrets must be copied
    # into the derivation output, so they are stored permanently and become accessible
    # to the host via the predictable output path for this derivation
    installPhase = ''
      mkdir -p "$out"
      # Ensure that the rekey command has already been executed.
      [[ -e "/${tmpSecretsDir}" ]] \
        || { echo "[1;31mNo rekeyed secrets were found, please (re)execute \`nix run .#rekey\`.[m" >&2; exit 1; }
      cp -r "${tmpSecretsDir}/." "$out"
    '';
  };
}
