{
  self,
  lib,
  pkgs,
  nixosConfigurations,
  ...
}: let
  inherit
    (lib)
    concatMapStrings
    concatStringsSep
    escapeShellArg
    filterAttrs
    mapAttrsToList
    removeSuffix
    substring
    ;

  rekeyCommandsForHost = hostName: hostAttrs: let
    inherit (hostAttrs.config.age.rekey) agePlugins masterIdentities;
    # The derivation containing the resulting rekeyed secrets
    rekeyedSecrets = import ../nix/output-derivation.nix pkgs hostAttrs.config;
    # We need to know where this derivation expects the rekeyed secrets to be stored
    inherit (rekeyedSecrets) tmpSecretsDir;
    # All secrets that have rekeyFile set. These will be rekeyed.
    secretsToRekey = filterAttrs (_: v: v.rekeyFile != null) hostAttrs.config.age.secrets;
    # Create the recipient argument that will be passed to rage
    hostPubkey = removeSuffix "\n" hostAttrs.config.age.rekey.hostPubkey;
    hostPubkeyOpt =
      if builtins.substring 0 1 hostPubkey == "/"
      then "-R"
      else "-r";

    # Collect paths to enabled age plugins for this host
    envPath = ''PATH="$PATH${concatMapStrings (x: ":${x}/bin") agePlugins}"'';
    # The identities which can decrypt the existing secrets need to be passed to rage
    masterIdentityArgs = concatMapStrings (x: ''-i ${escapeShellArg x} '') masterIdentities;
    # Finally, the command that rekeys a given secret.
    rekeyCommand = secretName: secretAttrs: let
      secretOut = "${tmpSecretsDir}/${secretName}.age";
    in ''
      echo "Rekeying ${secretName} (${secretAttrs.rekeyFile}) for host ${hostName}"
      if ! ${envPath} decrypt "${secretAttrs.rekeyFile}" "${secretName}" "${hostName}" ${masterIdentityArgs} \
        | ${envPath} ${pkgs.rage}/bin/rage -e ${hostPubkeyOpt} ${escapeShellArg hostPubkey} -o "${secretOut}"; then
        echo "[1;31mFailed to encrypt ${secretOut} for ${hostName}![m" >&2
      fi
    '';
  in ''
    # Remove old rekeyed secrets
    test -e "${tmpSecretsDir}" && rm -r "${tmpSecretsDir}"
    mkdir -p "${tmpSecretsDir}"

    # Rekey secrets for this host
    ${concatStringsSep "\n" (mapAttrsToList rekeyCommand secretsToRekey)}
  '';
in
  pkgs.writeShellScript "rekey" ''
    set -euo pipefail

    if [[ ! -e flake.nix ]] ; then
      echo "Please execute this script from your flake's root directory." >&2
      exit 1
    fi

    dummy_all=0
    function flush_stdin() {
      local empty_stdin
      while read -r -t 0.01 empty_stdin; do true; done
      true
    }

    # "$1" secret file
    # "$2" secret name
    # "$3" hostname
    # "$@" masterIdentityArgs
    function decrypt() {
      local response
      local secret_file=$1
      local secret_name=$2
      local hostname=$3
      shift 3

      # Outer loop, allows us to retry the command
      while true; do
        # Try command
        if ${pkgs.rage}/bin/rage -d "$@" "$secret_file"; then
          return
        fi

        echo "[1;31mFailed to decrypt age.secrets.$secret_name.rekeyFile ($secret_file) for $hostname![m" >&2
        while true; do
          if [[ "$dummy_all" == "true" ]]; then
            response=d
          else
            echo "  (y) retry" >&2
            echo "  (n) abort" >&2
            echo "  (d) use a dummy value instead" >&2
            echo "  (a) use a dummy value for all future failures" >&2
            echo -n "Select action (Y/n/d/a) " >&2
            flush_stdin
            read -r response
          fi
          case "''${response,,}" in
            ""|y|yes) continue 2 ;;
            n|no)
              echo "[1;31mAborted by user.[m" >&2
              exit 1
              ;;
            a) dummy_all=true ;&
            d|dummy)
              echo "This is a dummy replacement value. The actual secret age.secrets.$secret_name.rekeyFile ($secret_file) could not be decrypted."
              return
              ;;
            *) ;;
          esac
        done
      done
    }

    ${concatStringsSep "\n" (mapAttrsToList rekeyCommandsForHost nixosConfigurations)}
    # Pivot to another script that has /tmp available in its sandbox
    # and is impure in case the master key is located elsewhere on the system
    nix run --extra-sandbox-paths /tmp --impure "${self.outPath}#_rekey-save-outputs";
  ''
