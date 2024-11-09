{
  appHostPkgs,
  hostConfig,
}: let
  inherit
    (appHostPkgs.lib)
    assertMsg
    attrValues
    concatMapStrings
    escapeShellArg
    filterAttrs
    flip
    ;
  target = (import ./target-name.nix) {
    pkgs = appHostPkgs;
    config = hostConfig;
  };

  # All secrets that have rekeyFile set. These will be rekeyed.
  secretsToRekey = flip filterAttrs hostConfig.age.secrets (name: secret: let
    hint =
      if secret.generator != null
      then "Did you run `[32magenix generate[m` to generate it and have you added it to git?"
      else "Have you added it to git?";
  in
    assert assertMsg (secret.rekeyFile != null -> builtins.pathExists secret.rekeyFile) "age.secrets.${name}.rekeyFile ([33m${toString secret.rekeyFile}[m) doesn't exist. ${hint}";
      secret.rekeyFile != null);

  # Returns a bash expression that refers to the path where a particular
  # rekeyed secret is going to be saved.
  cachePathFor = secret: let
    pubkeyHash = builtins.hashString "sha256" hostConfig.age.rekey.hostPubkey;
    identHash =
      builtins.hashString "sha256"
      (pubkeyHash + builtins.hashFile "sha256" secret.rekeyFile);
  in
    hostConfig.age.rekey.cacheDir + "/secrets/${identHash}-${secret.name}.age";
in
  # This is the derivation that copies the rekeyed secrets into the nix-store.
  # We use mkDerivation here to building this derivatoin on any system while
  # allowing the result to be system-agnostic.
  appHostPkgs.stdenv.mkDerivation {
    name = "agenix-rekey-host-secrets";
    description = "Rekeyed secrets for ${target}";

    # No special inputs are necessary.
    dontUnpack = true;
    dontPatch = true;
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;
    dontCopyDist = true;

    # When this derivation is built, the rekeyed secrets must be copied
    # into the derivation output, so they are stored permanently and become accessible
    # to the host via the predictable output path for this derivation
    installPhase =
      ''
        set -euo pipefail
        mkdir -p "$out"

        function ensure_exists() {
          [[ -e "$1" ]] || {
            echo "[1;31mAt least one rekeyed secret is missing, please run \`agenix rekey\` again.[m" >&2
            echo "[90m  rekeyed secret: $1[m" >&2
            exit 1
          }
        }
      ''
      + flip concatMapStrings (attrValues secretsToRekey) (secret: ''
        ensure_exists ${cachePathFor secret}
        cp -v ${cachePathFor secret} "$out/"${escapeShellArg "${secret.name}.age"}
      '')
      + ''
        touch $out/success
      '';

    passthru = {
      inherit cachePathFor;
      inherit (hostConfig.age.rekey) cacheDir;
    };
  }
