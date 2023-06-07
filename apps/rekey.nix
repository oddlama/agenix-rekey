self: appHostPkgs: nixosConfigurations: let
  inherit
    (appHostPkgs.lib)
    warn
    hasPrefix
    filter
    removePrefix
    concatLists
    concatMapStrings
    concatStringsSep
    escapeShellArg
    filterAttrs
    mapAttrsToList
    removeSuffix
    substring
    unique
    ;

  mkApp = {drv}: {
    type = "app";
    program = "${drv}";
  };
in rec {
  rekey = mkApp {
    drv = let
      rekeyCommandsForHost = hostName: hostAttrs: let
        inherit (hostAttrs.config.age.rekey) agePlugins masterIdentities;
        # The derivation containing the resulting rekeyed secrets
        rekeyedSecrets = import ../nix/output-derivation.nix appHostPkgs hostAttrs.config;
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
            | ${envPath} ${appHostPkgs.rage}/bin/rage -e ${hostPubkeyOpt} ${escapeShellArg hostPubkey} -o "${secretOut}"; then
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
      appHostPkgs.writeShellScript "rekey" ''
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
            if ${appHostPkgs.rage}/bin/rage -d "$@" "$secret_file"; then
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
      '';
  };
  # Internal app that rekey pivots into. Do not call manually.
  _rekey-save-outputs = mkApp {
    drv = let
      copyHostSecrets = hostName: hostAttrs: let
        rekeyedSecrets = import ../nix/output-derivation.nix appHostPkgs hostAttrs.config;
      in ''echo "Stored rekeyed secrets for ${hostAttrs.config.networking.hostName} in ${rekeyedSecrets.drv}"'';
    in
      appHostPkgs.writeShellScript "_rekey-save-outputs" ''
        set -euo pipefail
        ${concatStringsSep "\n" (mapAttrsToList copyHostSecrets nixosConfigurations)}
      '';
  };
  # Create/edit a secret using your $EDITOR and automatically encrypt it using your specified master identities.
  edit-secret = mkApp {
    drv = let
      flakeDir = toString self.outPath;
      relativeToFlake = filePath:
        let fileStr = toString filePath; in
          if hasPrefix flakeDir fileStr
          then "." + removePrefix flakeDir fileStr
          else warn "Ignoring ${fileStr} which isn't a direct subpath of the flake directory ${flakeDir}, meaning this script cannot determine it's true origin!" null;

      mergeArray = f: unique (concatLists (mapAttrsToList (_: f) nixosConfigurations));
      mergedAgePlugins = mergeArray (x: x.config.age.rekey.agePlugins or []);
      mergedMasterIdentities = mergeArray (x: x.config.age.rekey.masterIdentities or []);
      mergedExtraEncryptionPubkeys = mergeArray (x: x.config.age.rekey.extraEncryptionPubkeys or []);
      mergedSecrets = mergeArray (x: filter (x: x != null) (mapAttrsToList (_: s: s.rekeyFile) x.config.age.secrets));
      # Relative path to all rekeyable secrets. Filters and warns on paths that are not part of the root flake.
      validRelativeSecretPaths = builtins.sort (a: b: a < b) (filter (x: x != null) (map relativeToFlake mergedSecrets));

      isAbsolutePath = x: substring 0 1 x == "/";
      envPath = ''PATH="$PATH${concatMapStrings (x: ":${x}/bin") mergedAgePlugins}"'';
      masterIdentityArgs = concatMapStrings (x: ''-i ${escapeShellArg x} '') mergedMasterIdentities;
      extraEncryptionPubkeys =
        concatMapStrings (
          x:
            if isAbsolutePath x
            then ''-R ${escapeShellArg x} ''
            else ''-r ${escapeShellArg x} ''
        )
        mergedExtraEncryptionPubkeys;
    in
      appHostPkgs.writeShellScript "edit-secret" ''
        set -uo pipefail

        function die() { echo "[1;31merror:[m $*" >&2; exit 1; }
        function show_help() {
          echo 'app edit-secret - create/edit age secret files with $EDITOR'
          echo ""
          echo "nix run .#edit-secret [FILE]"
          echo ""
          echo 'options:'
          echo '-h, --help                Show help'
          echo '-i, --input INFILE        Instead of editing FILE with $EDITOR, directly use the'
          echo '                            content of INFILE and encrypt it to FILE.'
          echo ""
          echo 'FILE    An age-encrypted file to edit or a new file to create.'
          echo '          If not given, a fzf selector of used secrets will be shown.'
          echo ""
          echo 'age plugins: ${concatStringsSep ", " mergedAgePlugins}'
          echo 'master identities: ${concatStringsSep ", " mergedMasterIdentities}'
          echo 'extra encryption pubkeys: ${concatStringsSep ", " mergedExtraEncryptionPubkeys}'
        }

        if [[ ! -e flake.nix ]] ; then
          echo "Please execute this script from your flake's root directory." >&2
          exit 1
        fi

        POSITIONAL_ARGS=()
        while [[ $# -gt 0 ]]; do
          case "$1" in
            "help"|"--help"|"-help"|"-h")
              show_help
              exit 1
              ;;
            "--input"|"-i")
              INFILE="$2"
              [[ -f "$INFILE" ]] || die "Input file not found: '$INFILE'"
              shift
              ;;
            "--") break ;;
            "-"*|"--"*) die "Invalid option '$1'" ;;
            *) POSITIONAL_ARGS+=("$1") ;;
          esac
          shift
        done

        # If file is not given, show fzf
        case "''${#POSITIONAL_ARGS[@]}" in
          0)
            FILE=$(echo ${escapeShellArg (concatStringsSep "\n" validRelativeSecretPaths)} \
              | ${appHostPkgs.fzf}/bin/fzf --tiebreak=end --bind=tab:down,btab:up,change:top --height='~50%' --tac --cycle --layout=reverse) \
              || die "No file selected. Aborting."
          ;;
          1) FILE="''${POSITIONAL_ARGS[0]}" ;;
          *)
            show_help
            exit 1
            ;;
        esac
        [[ "$FILE" != *".age" ]] && echo "[1;33mwarning:[m secrets should use the .age suffix by convention"

        CLEARTEXT_FILE=$(${appHostPkgs.mktemp}/bin/mktemp)
        ENCRYPTED_FILE=$(${appHostPkgs.mktemp}/bin/mktemp)

        function cleanup() {
          [[ -e "$CLEARTEXT_FILE" ]] && rm "$CLEARTEXT_FILE"
          [[ -e "$ENCRYPTED_FILE" ]] && rm "$ENCRYPTED_FILE"
        }; trap "cleanup" EXIT

        if [[ -e "$FILE" ]]; then
          [[ -z ''${INFILE+x} ]] || die "Refusing to overwrite existing file when using --input"

          ${envPath} ${appHostPkgs.rage}/bin/rage -d ${masterIdentityArgs} -o "$CLEARTEXT_FILE" "$FILE" \
            || die "Failed to decrypt file. Aborting."
        else
          mkdir -p "$(dirname "$FILE")" \
            || die "Could not create parent directory"
        fi
        shasum_before="$(sha512sum "$CLEARTEXT_FILE")"

        if [[ -n ''${INFILE+x} ]] ; then
          cp "$INFILE" "$CLEARTEXT_FILE"
        else
          # Editor options to prevent leaking information
          EDITOR_OPTS=()
          case "$EDITOR" in
            vim|"vim "*|nvim|"nvim "*)
              EDITOR_OPTS=("--cmd" 'au BufRead * setlocal history=0 nobackup nomodeline noshelltemp noswapfile noundofile nowritebackup secure viminfo=""') ;;
            *) ;;
          esac
          $EDITOR "''${EDITOR_OPTS[@]}" "$CLEARTEXT_FILE" \
            || die "Editor returned unsuccessful exit status. Aborting, original is left unchanged."
        fi

        shasum_after="$(sha512sum "$CLEARTEXT_FILE")"
        if [[ "$shasum_before" == "$shasum_after" ]]; then
          echo "No content changes, original is left unchanged."
          exit 0
        fi

        ${envPath} ${appHostPkgs.rage}/bin/rage -e ${masterIdentityArgs} ${extraEncryptionPubkeys} -o "$ENCRYPTED_FILE" "$CLEARTEXT_FILE" \
          || die "Failed to (re)encrypt edited file, original is left unchanged."
        cp --no-preserve=all "$ENCRYPTED_FILE" "$FILE" # cp instead of mv preserves original attributes and permissions

        exit 0
      '';
  };
}
