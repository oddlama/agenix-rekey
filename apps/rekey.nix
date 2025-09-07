{
  pkgs,
  nodes,
  ...
}@inputs:
let
  inherit (pkgs.lib)
    assertMsg
    attrValues
    concatMapStrings
    concatStringsSep
    escapeShellArg
    escapeShellArgs
    filterAttrs
    flip
    hasPrefix
    makeBinPath
    mapAttrsToList
    removePrefix
    ;

  inherit (import ../nix/lib.nix inputs)
    userFlakeDir
    ageHostEncrypt
    ageMasterDecrypt
    ;

  # The derivation containing the resulting rekeyed secrets for
  # the given host configuration
  derivationFor =
    hostCfg:
    import ../nix/output-derivation.nix {
      appHostPkgs = pkgs;
      hostConfig = hostCfg.config;
    };

  # Returns the outPath/drvPath for the secrets of a given host, without
  # triggering a build of the derivation.
  outPathFor =
    hostCfg: builtins.unsafeDiscardStringContext (toString (derivationFor hostCfg).outPath);
  drvPathFor =
    hostCfg: builtins.unsafeDiscardStringContext (toString (derivationFor hostCfg).drvPath);

  nodesWithDerivationStorage = attrValues (
    filterAttrs (
      n: v:
      # This is our first time accessing the age and age.rekey properties.
      # If both agenix and agenix-rekey are not loaded onto the node being
      # processed, `agenix rekey` will fail.  This is our opportunity to
      # inform the user which node is problematic and what must be done to
      # address the issue.
      assert assertMsg (v.config ? age) ''
        Node "${n}" is missing the agenix module.
        agenix-rekey cannot continue until all nodes include the agenix module.
      '';
      assert assertMsg (v.config.age ? rekey) ''
        Node "${n}" is missing the agenix-rekey module.
        agenix-rekey cannot continue until all nodes include the agenix-rekey module.
      '';
      v.config.age.rekey.storageMode == "derivation"
    ) nodes
  );

  rekeyCommandsForHost =
    hostName: hostCfg:
    let
      # All secrets that have rekeyFile set. These will be rekeyed.
      secretsToRekey = flip filterAttrs hostCfg.config.age.secrets (
        name: secret:
        let
          hint =
            if secret.generator != null then
              "Did you run `[32magenix generate[m` to generate it and have you added it to git?"
            else
              "Have you added it to git?";
        in
        assert assertMsg (
          secret.rekeyFile != null -> builtins.pathExists secret.rekeyFile
        ) "age.secrets.${name}.rekeyFile ([33m${toString secret.rekeyFile}[m) doesn't exist. ${hint}";
        secret.rekeyFile != null
      );
    in
    if
      hostCfg.config.age.rekey.hostPubkey
      == "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq"
    then
      ''
        echo "[1;90m    Skipping[m [90m[dummy hostPubkey] "${escapeShellArg hostName}"[m"
      ''
    else
      {
        derivation =
          let
            # The derivation containing the resulting rekeyed secrets
            rekeyedSecrets = derivationFor hostCfg;

            # The resulting store path for this host's rekeyed secrets
            outPath = escapeShellArg (outPathFor hostCfg);
            # The builder which we can use to realise the derivation
            drvPath = escapeShellArg (drvPathFor hostCfg);

            rekeyCommand =
              secretName: secret:
              let
                secretOut = rekeyedSecrets.cachePathFor secret;
              in
              ''
                if [[ -e ${secretOut} ]] && [[ "$FORCE" != true ]]; then
                  echo "[1;90m    Skipping[m [90m[already rekeyed] "${escapeShellArg hostName}":"${escapeShellArg secretName}"[m"
                else
                  echo "[1;32m    Rekeying[m [90m"${escapeShellArg hostName}":[34m"${escapeShellArg secretName}"[m"
                  # Don't escape the out path as it could contain variables we want to expand
                  if reencrypt "${secretOut}" ${
                    escapeShellArgs [
                      secret.rekeyFile
                      secretName
                      hostName
                    ]
                  }; then
                    any_rekeyed=true
                  else
                    echo "[1;31mFailed to re-encrypt ${secret.rekeyFile} for ${hostName}![m" >&2
                  fi
                fi
              '';
          in
          ''
            # Called in `reencrypt`
            function encrypt() {
              ${ageHostEncrypt hostCfg} "$@"
            }

            ANY_DERIVATION_MODE_HOSTS=true
            will_delete=false
            # Remove any existing rekeyed secrets from the nix store if --force was given
            if [[ -e ${outPath} && ( "$FORCE" == true || ! -e ${outPath}/success ) ]]; then
              echo "[1;31m     Marking[m [31mexisting store path of [33m"${escapeShellArg hostName}"[31m for deletion [90m("${outPath}")[m"
              STORE_PATHS_TO_DELETE+=(${outPath})
              will_delete=true
            fi

            any_rekeyed=false
            # Rekey secrets for ${hostName}
            mkdir -p ${rekeyedSecrets.cacheDir}/secrets
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
        local =
          let
            relativeToFlake =
              filePath:
              let
                fileStr = builtins.unsafeDiscardStringContext (toString filePath);
              in
              if hasPrefix userFlakeDir fileStr then
                "." + removePrefix userFlakeDir fileStr
              else
                throw "Cannot determine true origin of ${fileStr} which doesn't seem to be a direct subpath of the flake directory ${userFlakeDir}. Did you make sure to specify `age.rekey.localStorageDir` relative to the root of your flake?";

            hostRekeyDir = relativeToFlake hostCfg.config.age.rekey.localStorageDir;
            rekeyCommand =
              secretName: secret:
              let
                pubkeyHash = builtins.hashString "sha256" hostCfg.config.age.rekey.hostPubkey;
                identHash = builtins.substring 0 32 (
                  builtins.hashString "sha256" (pubkeyHash + builtins.hashFile "sha256" secret.rekeyFile)
                );
                secretOut = "${hostRekeyDir}/${identHash}-${secret.name}.age";
              in
              ''
                # Mark secret as known
                TRACKED_SECRETS[${escapeShellArg secretOut}]=true

                if [[ -e ${escapeShellArg secretOut} ]] && [[ "$FORCE" != true ]]; then
                  echo "[1;90m    Skipping[m [90m[already rekeyed] "${escapeShellArg hostName}":"${escapeShellArg secretName}"[m"
                else
                  echo "[1;32m    Rekeying[m [90m"${escapeShellArg hostName}":[34m"${escapeShellArg secretName}"[m"
                  if ! reencrypt ${
                    escapeShellArgs [
                      secretOut
                      secret.rekeyFile
                      secretName
                      hostName
                    ]
                  }; then
                    echo "[1;31mFailed to re-encrypt ${secret.rekeyFile} for ${hostName}![m" >&2
                  fi
                fi
              '';
          in
          ''
            # Called in `reencrypt`
            function encrypt() {
              ${ageHostEncrypt hostCfg} "$@"
            }

            # Create a set of tracked secrets so we can remove orphaned files afterwards
            unset TRACKED_SECRETS
            declare -A TRACKED_SECRETS=() # the `=()` is required otherwise accessing the length fails with `unbound variable` 

            # Rekey secrets for ${hostName}
            mkdir -p ${hostRekeyDir}
            ${concatStringsSep "\n" (mapAttrsToList rekeyCommand secretsToRekey)}

            # Remove orphaned files
            REMOVED_ORPHANS=0
            (
              shopt -s nullglob
              while read -d $'\0' f; do
                if [[ "''${TRACKED_SECRETS["$f"]-false}" == false ]]; then
                  rm -- "$f" || true
                  REMOVED_ORPHANS=$((REMOVED_ORPHANS + 1))
                fi
              done < <(find ${escapeShellArg hostRekeyDir} -type f -print0)
              find ${escapeShellArg hostRekeyDir} -type d -empty -delete
              if [[ "''${REMOVED_ORPHANS}" -gt 0 ]]; then
                echo "[1;36m     Removed[m [0;33m''${REMOVED_ORPHANS} [0;36morphaned files for [32m"${escapeShellArg hostName}" [90min ${escapeShellArg hostRekeyDir}[m"
              fi
            )

            if [[ "$ADD_TO_GIT" == true && "''${#TRACKED_SECRETS[@]}" -gt 0 || "''${REMOVED_ORPHANS}" -gt 0 ]]; then
              git add ./${escapeShellArg hostRekeyDir}
            fi
          '';
      }
      .${hostCfg.config.age.rekey.storageMode};

  # Appended to the `PATH` environment variable.  Executables in the user's
  # current environment take precedence over these; they are here only as
  # backups in case the current environment lacks (e.g.) `nix`.
  binPath = makeBinPath (
    with pkgs;
    [
      coreutils
      findutils
      nix
    ]
  );
in
pkgs.writeShellScriptBin "agenix-rekey" ''
  set -euo pipefail

  export PATH="''${PATH:+"''${PATH}:"}"${escapeShellArg binPath}

  function die() { echo "[1;31merror:[m $*" >&2; exit 1; }
  function show_help() {
    echo 'Usage: agenix rekey [OPTIONS]'
    echo "Re-encrypts secrets for hosts that require them."
    echo ""
    echo 'OPTIONS:'
    echo '-h, --help                Show help'
    echo '-a, --add-to-git          Add rekeyed secrets to git via git add. (Only used for hosts with storageMode=local)'
    echo '-d, --dummy               Always create dummy secrets when rekeying, which'
    echo '                            can be useful for testing builds in a CI'
    echo '-f, --force               Always rekey everything regardless of whether a'
    echo '                            matching derivation/local file already exists. If you previously used'
    echo '                            dummy values while rekeying you can use this to force rekeying'
    echo '                            even though there are technically no changes to the inputs.'
    echo '                            This will fail if the resulting derivation is currently in'
    echo '                            use by the system (reachable by a GC root).'
    echo '    --show-out-paths      Instead of rekeying, show the output paths of all resulting'
    echo '                            derivations, one path per host. The paths may not yet exist'
    echo '                            if secrets were not rekeyed recently. (Only considers hosts with storageMode=derivation)'
    echo '    --show-drv-paths      Instead of rekeying, show the paths of .drv files used to'
    echo '                            realise the resulting derivations, one path per host. (Only considers hosts with storageMode=derivation)'
  }

  function show_out_paths() {
    true # in case list is empty
    ${concatMapStrings (x: "echo ${escapeShellArg (outPathFor x)}\n") nodesWithDerivationStorage}
  }

  function show_drv_paths() {
    true # in case list is empty
    ${concatMapStrings (x: "echo ${escapeShellArg (drvPathFor x)}\n") nodesWithDerivationStorage}
  }

  function encrypt() {
    die "internal error: ''${FUNCNAME[0]:-encrypt} must be implemented on a per-host basis"
  }

  # Re-encrypt a secret file.  Requires the `encrypt` function to be defined to
  # run an encrypting command appropriate for the target host.
  #
  # Features:
  #
  #   1. Creates secret files atomically by (a) writing the re-encrypted secret
  #      into a temporary directory on the same filesystem as the final output
  #      path and (b) moving the re-encrypted secret to its final output path
  #      with `mv -f`.
  #
  #   2. Avoids the "unsafe" (quoth `man 1 mktemp`) `--dry-run` option to the
  #      `mktemp` command, instead creating a temporary directory and writing
  #      the re-encrypted secret to a file within that directory.
  #
  function reencrypt() {
    local out="''${1?internal error}"
    shift 2>/dev/null || :

    local name="$(basename "$out")"
    local dir="$(dirname "$out")"

    mkdir -p "$dir" || return

    local tmpdir
    tmpdir="$(${pkgs.coreutils}/bin/mktemp -d "''${dir}/.tmp.agenix-rekey.''${name}.XXXXXXXXXX")" || return

    local tmp="''${tmpdir}/''${name}"

    # Make sure to only create the result file if the rekeying was actually
    # successful.  If the first command in the pipe fails, we otherwise create
    # a validly encrypted but empty secret
    decrypt "$@" | encrypt -o "$tmp" || {
      local -i rc="$?"
      rm -f "$tmp" || :
      rmdir "$tmpdir" || echo "[1;31mFailed to remove temporary directory ''${tmpdir} after failing to re-encrypt secret ''${out}![m" >&2
      return "$rc"
    }

    local -i rc=0
    mv -f "$tmp" "$out" || rc="$?"
    rmdir "$tmpdir" || echo "[1;31mFailed to remove temporary directory ''${tmpdir} after re-encrypting secret ''${out}![m" >&2
    return "$rc"
  }

  DUMMY=false
  FORCE=false
  ADD_TO_GIT=''${AGENIX_REKEY_ADD_TO_GIT-false}
  while [[ $# -gt 0 ]]; do
    case "$1" in
      "help"|"--help"|"-help"|"-h")
        show_help
        exit 1
        ;;
      "-a"|"--add-to-git") ADD_TO_GIT=true ;;
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
      if ${ageMasterDecrypt} "$secret_file"; then
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
  ANY_DERIVATION_MODE_HOSTS=false

  ${concatStringsSep "\n" (mapAttrsToList rekeyCommandsForHost nodes)}

  if [[ "$ANY_DERIVATION_MODE_HOSTS" == true ]]; then
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
  fi
''
