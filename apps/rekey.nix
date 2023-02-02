{
  self,
  nixpkgs, # FIXME: technically this is an input to the parent flake and might not exist
  flake-utils, # FIXME: technically this is an input to the parent flake and might not exist
  ...
}: system: nixosConfigurations:
with nixpkgs.lib;
with flake-utils.lib; let
  pkgs = import nixpkgs {inherit system;};
in rec {
  rekey = mkApp {
    drv = let
      rekeyCommandsForHost = hostName: hostAttrs: let
        rekeyedSecrets = import ../nix/output-derivation.nix pkgs hostAttrs.config;
        inherit (rekeyedSecrets) tmpSecretsDir;
        inherit (hostAttrs.config.rekey) agePlugins hostPubkey masterIdentities secrets;

        # Collect paths to enabled age plugins for this host
        envPath = ''PATH="$PATH${concatMapStrings (x: ":${x}/bin") agePlugins}"'';
        masterIdentityArgs = concatMapStrings (x: ''-i "${x}" '') masterIdentities;
        rekeyCommand = secretName: secretAttrs: let
          secretOut = "${tmpSecretsDir}/${secretName}.age";
        in ''
          echo "Rekeying ${secretName} (${secretAttrs.file}) for host ${hostName}"
          ${envPath} decrypt "${secretAttrs.file}" "${secretName}" "${hostName}" ${masterIdentityArgs} \
            | ${envPath} ${pkgs.rage}/bin/rage -r "${hostPubkey}" -o "${secretOut}" -e
        '';
      in ''
        # Remove old rekeyed secrets
        test -e "${tmpSecretsDir}" && rm -r "${tmpSecretsDir}"
        mkdir -p "${tmpSecretsDir}"

        # Rekey secrets for this host
        ${concatStringsSep "\n" (mapAttrsToList rekeyCommand secrets)}
      '';
    in
      pkgs.writeShellScriptBin "rekey" ''
        set -euo pipefail

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
            if ${pkgs.rage}/bin/rage "$@" -d "$secret_file"; then
              return
            fi

            echo "[1;31mFailed to decrypt rekey.secrets.$secret_name ($secret_file) for $hostname![m" >&2
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
                  echo "This is a dummy replacement value. The actual secret rekey.secrets.$secret_name ($secret_file) could not be decrypted."
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
        nix run --extra-sandbox-paths /tmp --impure "${self.outPath}#rekey-save-outputs";
      '';
  };
  # Internal app that rekey pivots into. Do not call manually.
  rekey-save-outputs = mkApp {
    drv = let
      copyHostSecrets = hostName: hostAttrs: let
        rekeyedSecrets = import ../nix/output-derivation.nix pkgs hostAttrs.config;
      in ''echo "Stored rekeyed secrets for ${hostAttrs.config.networking.hostName} in ${rekeyedSecrets.drv}"'';
    in
      pkgs.writeShellScriptBin "rekey-save-outputs" ''
        set -euo pipefail
        ${concatStringsSep "\n" (mapAttrsToList copyHostSecrets nixosConfigurations)}
      '';
  };
  # Create/edit a secret using your $EDITOR and automatically encrypt it using your specified master identities.
  edit-secret = mkApp {
    drv = pkgs.writeShellScriptBin "edit-secret" ''
        set -euo pipefail

        function show_help() {
          echo 'app edit-secret - create/edit age secret files with $EDITOR'
          echo ""
          echo "nix run '.#edit-secret' FILE"
          echo ""
          echo 'options:'
          echo '-h, --help                show help'
          echo ""
          echo 'FILE an age-encrypted file to edit or a new'
          echo '     file to create'
        }
        [[ $# -eq 0 ||  ]] && { show_help; exit 1; }
        REKEY=0
        DEFAULT_DECRYPT=(--decrypt)
        while test $# -gt 0; do
          case "$1" in
            -h|--help)
              show_help
              exit 0
              ;;
            *)
              show_help
              exit 1
              ;;
          esac
        done
        RULES=''${RULES:-./secrets.nix}
        function cleanup {
            if [ ! -z ''${CLEARTEXT_DIR+x} ]
            then
                rm -rf "$CLEARTEXT_DIR"
            fi
            if [ ! -z ''${REENCRYPTED_DIR+x} ]
            then
                rm -rf "$REENCRYPTED_DIR"
            fi
        }
        trap "cleanup" 0 2 3 15
        function edit {
            FILE=$1
            KEYS=$((${nixInstantiate} --eval -E "(let rules = import $RULES; in builtins.concatStringsSep \"\n\" rules.\"$FILE\".publicKeys)" | ${sedBin} 's/"//g' | ${sedBin} 's/\\n/\n/g') | ${sedBin} '/^$/d' || exit 1)
            if [ -z "$KEYS" ]
            then
                >&2 echo "There is no rule for $FILE in $RULES."
                exit 1
            fi
            CLEARTEXT_DIR=$(${mktempBin} -d)
            CLEARTEXT_FILE="$CLEARTEXT_DIR/$(basename "$FILE")"
            if [ -f "$FILE" ]
            then
                DECRYPT=("''${DEFAULT_DECRYPT[@]}")
                if [ -f "$HOME/.ssh/id_rsa" ]; then
                    DECRYPT+=(--identity "$HOME/.ssh/id_rsa")
                fi
                if [ -f "$HOME/.ssh/id_ed25519" ]; then
                    DECRYPT+=(--identity "$HOME/.ssh/id_ed25519")
                fi
                if [[ "''${DECRYPT[*]}" != *"--identity"* ]]; then
                  echo "No identity found to decrypt $FILE. Try adding an SSH key at $HOME/.ssh/id_rsa or $HOME/.ssh/id_ed25519 or using the --identity flag to specify a file."
                  exit 1
                fi
                DECRYPT+=(-o "$CLEARTEXT_FILE" "$FILE")
                ${ageBin} "''${DECRYPT[@]}" || exit 1
                cp "$CLEARTEXT_FILE" "$CLEARTEXT_FILE.before"
            fi
            $EDITOR "$CLEARTEXT_FILE"
            if [ ! -f "$CLEARTEXT_FILE" ]
            then
              echo "$FILE wasn't created."
              return
            fi
            [ -f "$FILE" ] && [ "$EDITOR" != ":" ] && ${diffBin} "$CLEARTEXT_FILE.before" "$CLEARTEXT_FILE" 1>/dev/null && echo "$FILE wasn't changed, skipping re-encryption." && return
            ENCRYPT=()
            while IFS= read -r key
            do
                ENCRYPT+=(--recipient "$key")
            done <<< "$KEYS"
            REENCRYPTED_DIR=$(${mktempBin} -d)
            REENCRYPTED_FILE="$REENCRYPTED_DIR/$(basename "$FILE")"
            ENCRYPT+=(-o "$REENCRYPTED_FILE")
            ${ageBin} "''${ENCRYPT[@]}" <"$CLEARTEXT_FILE" || exit 1
            mv -f "$REENCRYPTED_FILE" "$1"
        }
        function rekey {
            FILES=$((${nixInstantiate} --eval -E "(let rules = import $RULES; in builtins.concatStringsSep \"\n\" (builtins.attrNames rules))"  | ${sedBin} 's/"//g' | ${sedBin} 's/\\n/\n/g') || exit 1)
            for FILE in $FILES
            do
                echo "rekeying $FILE..."
                EDITOR=: edit "$FILE"
                cleanup
            done
        }
        [ $REKEY -eq 1 ] && rekey && exit 0
        edit "$FILE" && cleanup && exit 0
      '';
  };
}
