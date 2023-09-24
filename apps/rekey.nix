{
  pkgs,
  nodes,
  ...
} @ inputs: let
  inherit
    (pkgs.lib)
    attrValues
    concatMapStrings
    concatStringsSep
    escapeShellArg
    filterAttrs
    mapAttrsToList
    ;

  inherit
    (import ../nix/lib.nix inputs)
    rageHostEncrypt
    rageMasterDecrypt
    ;

  # The derivation containing the resulting rekeyed secrets for
  # the given host configuration
  derivationFor = hostCfg:
    import ../nix/output-derivation.nix {
      appHostPkgs = pkgs;
      hostConfig = hostCfg.config;
    };

  # Returns the outPath/drvPath for the secrets of a given host, without
  # triggering a build of the derivation.
  outPathFor = hostCfg: builtins.unsafeDiscardStringContext (toString (derivationFor hostCfg).outPath);
  drvPathFor = hostCfg: builtins.unsafeDiscardStringContext (toString (derivationFor hostCfg).drvPath);

  rekeyCommandsForHost = hostName: hostCfg: let
    # The derivation containing the resulting rekeyed secrets
    rekeyedSecrets = derivationFor hostCfg;

    # All secrets that have rekeyFile set. These will be rekeyed.
    secretsToRekey = filterAttrs (_: v: v.rekeyFile != null) hostCfg.config.age.secrets;
    # The resulting store path for this host's rekeyed secrets
    outPath = escapeShellArg (outPathFor hostCfg);
    # The builder which we can use to realise the derivation
    drvPath = escapeShellArg (drvPathFor hostCfg);

    # Finally, the command that rekeys a given secret.
    rekeyCommand = secretName: secret: let
      secretOut = rekeyedSecrets.cachePathFor secret;
    in ''
      if [[ -e ${secretOut} ]] && [[ "$FORCE" != true ]]; then
        echo "[1;90m    Skipping[m [90m[already rekeyed] "${escapeShellArg hostName}":"${escapeShellArg secretName}"[m"
      else
        mkdir -p ${rekeyedSecrets.cacheDir}/secrets
        rm ${secretOut}.tmp &>/dev/null || true
        echo "[1;32m    Rekeying[m [90m"${escapeShellArg hostName}":[34m"${escapeShellArg secretName}"[m"
        if ! decrypt ${escapeShellArg secret.rekeyFile} ${escapeShellArg secretName} ${escapeShellArg hostName} \
          | ${rageHostEncrypt hostCfg} -o ${secretOut}.tmp; then
          echo "[1;31mFailed to re-encrypt ${secret.rekeyFile} for ${hostName}![m" >&2
        fi
        # Make sure to only create the result file if the rekeying was actually successful.
        # If the first command in the pipe fails, we otherwise create a validly encrypted but empty secret
        mv ${secretOut}.tmp ${secretOut}
        any_rekeyed=true
      fi
    '';
  in ''
    will_delete=false
    # Remove any existing rekeyed secrets from the nix store if --force was given
    if [[ -e ${outPath} && ( "$FORCE" == true || ! -e ${outPath}/success ) ]]; then
      echo "[1;31m     Marking[m [31mexisting store path of [33m"${escapeShellArg hostName}"[31m for deletion [90m("${outPath}")[m"
      STORE_PATHS_TO_DELETE+=(${outPath})
      will_delete=true
    fi

    any_rekeyed=false
    # Rekey secrets for ${hostName}
    ${concatStringsSep "\n" (mapAttrsToList rekeyCommand secretsToRekey)}

    # We need to save the rekeyed output when any secret was rekeyed, or when the
    # output derivation doesn't exist (it could have been removed manually).
    if [[ "$any_rekeyed" == true || ! -e ${outPath} || "$will_delete" == true ]]; then
      SANDBOX_PATHS[${rekeyedSecrets.cacheDir}]=1
      [[ ${rekeyedSecrets.cacheDir} =~ [[:space:]] ]] \
        && die "The path to the rekeyed secret cannot contain spaces (i.e. neither cacheDir nor name) due to a limitation of nix --extra-sandbox-paths."
      DRVS_TO_BUILD+=(${drvPath}'^*')
    fi
  '';
in
  pkgs.writeShellScriptBin "agenix-rekey" ''
    set -euo pipefail

    function die() { echo "[1;31merror:[m $*" >&2; exit 1; }
    function show_help() {
      echo 'Usage: agenix rekey [OPTIONS]'
      echo "Re-encrypts secrets for hosts that require them."
      echo ""
      echo 'OPTIONS:'
      echo '-h, --help                Show help'
      echo '-d, --dummy               Always create dummy secrets when rekeying, which'
      echo '                            can be useful for testing builds in a CI'
      echo '-f, --force               Always rekey everything regardless of whether a'
      echo '                            matching derivation already exists. If you previously used'
      echo '                            dummy values while rekeying you can use this to force rekeying'
      echo '                            even though there are technically no changes to the inputs.'
      echo '                            This will fail if the resulting derivation is currently in'
      echo '                            use by the system (reachable by a GC root).'
      echo '    --show-out-paths      Instead of rekeying, show the output paths of all resulting'
      echo '                            derivations, one path per host. The paths may not yet exist'
      echo '                            if secrets were not rekeyed recently.'
      echo '    --show-drv-paths      Instead of rekeying, show the paths of .drv files used to'
      echo '                            realise the resulting derivations, one path per host.'
    }

    function show_out_paths() {
      ${concatMapStrings (x: "echo ${escapeShellArg (outPathFor x)}\n") (attrValues nodes)}
    }

    function show_drv_paths() {
      ${concatMapStrings (x: "echo ${escapeShellArg (drvPathFor x)}\n") (attrValues nodes)}
    }

    DUMMY=false
    FORCE=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        "help"|"--help"|"-help"|"-h")
          show_help
          exit 1
          ;;
        "-d"|"--dummy") DUMMY=true ;;
        "-f"|"--force") FORCE=true ;;
        "--show-out-paths")
          show_out_paths
          exit 0
          ;;
        "--show-drv-paths")
          show_drv_paths
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

    # Abuse an associative array as a set
    declare -A SANDBOX_PATHS
    STORE_PATHS_TO_DELETE=()
    DRVS_TO_BUILD=()

    ${concatStringsSep "\n" (mapAttrsToList rekeyCommandsForHost nodes)}

    if [[ "''${#STORE_PATHS_TO_DELETE[@]}" -gt 0 ]]; then
      echo "[1;31m    Deleting[m [31m''${#STORE_PATHS_TO_DELETE[@]} marked store paths[m"
      nix store delete "''${STORE_PATHS_TO_DELETE[@]}" 2>/dev/null
    fi

    if [[ "''${#DRVS_TO_BUILD[@]}" -gt 0 ]]; then
      echo "[1;32m   Realizing[m [32m''${#DRVS_TO_BUILD[@]} store paths[m"
      nix build --no-link --extra-sandbox-paths "''${!SANDBOX_PATHS[*]}" --impure "''${DRVS_TO_BUILD[@]}"
    else
      echo "Already up to date."
    fi
  ''
