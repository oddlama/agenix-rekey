{
  self,
  lib,
  pkgs,
  nixosConfigurations,
  ...
} @ inputs: let
  inherit
    (lib)
    concatMapStrings
    concatStringsSep
    escapeShellArg
    filterAttrs
    mapAttrsToList
    removeSuffix
    ;

  inherit
    (import ../nix/lib.nix inputs)
    rageMasterDecrypt
    rageHostEncrypt
    ;

  # The derivation containing the resulting rekeyed secrets for
  # the given host configuration
  derivationFor = hostCfg:
    import ../nix/output-derivation.nix {
      appHostPkgs = pkgs;
      hostConfig = hostCfg.config;
    };

  showOutPath = _: hostCfg: "echo ${escapeShellArg (derivationFor hostCfg).drv}";

  rekeyCommandsForHost = hostName: hostCfg: let
    # The derivation containing the resulting rekeyed secrets
    rekeyedSecrets = import ../nix/output-derivation.nix {
      appHostPkgs = pkgs;
      hostConfig = hostCfg.config;
    };
    # We need to know where this derivation expects the rekeyed secrets to be stored
    inherit (rekeyedSecrets) tmpSecretsDir;
    # All secrets that have rekeyFile set. These will be rekeyed.
    secretsToRekey = filterAttrs (_: v: v.rekeyFile != null) hostCfg.config.age.secrets;

    # Finally, the command that rekeys a given secret.
    rekeyCommand = secretName: secret: let
      secretOut = "${tmpSecretsDir}/${secretName}.age";
    in ''
      echo "Rekeying ${secretName} for host ${hostName}"
      if ! decrypt ${escapeShellArg secret.rekeyFile} ${escapeShellArg secretName} ${escapeShellArg hostName} \
        | ${rageHostEncrypt hostCfg} -o ${escapeShellArg secretOut}; then
        echo "[1;31mFailed to re-encrypt ${secret.rekeyFile} for ${hostName}![m" >&2
      fi
    '';
  in ''
    # Remove old rekeyed secrets
    test -e "${tmpSecretsDir}" && rm -r "${tmpSecretsDir}"
    mkdir -p "${tmpSecretsDir}"

    # Rekey secrets for ${hostName}
    ${concatStringsSep "\n" (mapAttrsToList rekeyCommand secretsToRekey)}
  '';
in
  pkgs.writeShellScript "rekey" ''
    set -euo pipefail

    function die() { echo "[1;31merror:[m $*" >&2; exit 1; }
    function show_help() {
      echo 'app rekey - Re-encrypts secrets for hosts that require them'
      echo ""
      echo "nix run .#rekey [OPTIONS]"
      echo ""
      echo 'OPTIONS:'
      echo '-h, --help                Show help'
      echo '-d, --dummy               Always create dummy secrets when rekeying, which'
      echo '                            can be useful for testing builds in a CI'
      echo '    --show-out-paths      Instead of rekeying, show the output paths of all resulting'
      echo '                            derivations, one path per host. The paths may not yet exist'
      echo '                            if secrets were not rekeyed recently.'
    }

    function show_out_paths() {
      ${concatStringsSep "\n" (mapAttrsToList showOutPath nixosConfigurations)}
    }

    DUMMY=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        "help"|"--help"|"-help"|"-h")
          show_help
          exit 1
          ;;
        "-d"|"--dummy") DUMMY=true ;;
        "--show-out-paths")
          show_out_paths
          exit 0
          ;;
        *) die "Invalid option '$1'" ;;
      esac
      shift
    done

    if [[ ! -e flake.nix ]] ; then
      die "Please execute this script from your flake's root directory."
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
    function decrypt() {
      local response
      local secret_file=$1
      local secret_name=$2
      local hostname=$3
      shift 3

      if [[ "$DUMMY" == true ]]; then
        echo "This is a dummy replacement value. The actual secret age.secrets.$secret_name.rekeyFile ($secret_file) was not rekeyed because --dummy was used."
        return
      fi

      # Outer loop, allows us to retry the command
      while true; do
        # Try command
        if ${rageMasterDecrypt} "$secret_file"; then
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
