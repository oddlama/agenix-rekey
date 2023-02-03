# TODO consolidate nixpkgs and system in to pkgs?
self: nixpkgs: system: nixosConfigurations:
with nixpkgs.lib; let
  pkgs = import nixpkgs {inherit system;};
  mkApp = { drv }: {
    type = "app";
    program = "${drv}";
  };
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
            | ${envPath} ${pkgs.rage}/bin/rage -e -r "${hostPubkey}" -o "${secretOut}"
        '';
      in ''
        # Remove old rekeyed secrets
        test -e "${tmpSecretsDir}" && rm -r "${tmpSecretsDir}"
        mkdir -p "${tmpSecretsDir}"

        # Rekey secrets for this host
        ${concatStringsSep "\n" (mapAttrsToList rekeyCommand secrets)}
      '';
    in
      pkgs.writeShellScript "rekey" ''
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
            if ${pkgs.rage}/bin/rage -d "$@" "$secret_file"; then
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
      pkgs.writeShellScript "rekey-save-outputs" ''
        set -euo pipefail
        ${concatStringsSep "\n" (mapAttrsToList copyHostSecrets nixosConfigurations)}
      '';
  };
  # Create/edit a secret using your $EDITOR and automatically encrypt it using your specified master identities.
  edit-secret = mkApp {
    drv = let
      inherit (hostAttrs.config.rekey) agePlugins masterIdentities secrets;
      # TODO warn if editing secret that isn't used
      envPath = ''PATH="$PATH${concatMapStrings (x: ":${x}/bin") agePlugins}"'';
      masterIdentityArgs = concatMapStrings (x: ''-i "${x}" '') masterIdentities;
    in pkgs.writeShellScript "edit-secret" ''
        set -uo pipefail

        function die() { echo "$*" >&2; exit 1; }
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
        [[ $# -eq 0 || "$1" == "--help" ]] && { show_help; exit 1; }

        FILE="$1"
        CLEARTEXT_FILE=$(${pkgs.mktemp}/bin/mktemp)
        ENCRYPTED_FILE=$(${pkgs.mktemp}/bin/mktemp)

        function cleanup() {
            [[ -e ''${CLEARTEXT_FILE} ]] && rm "$CLEARTEXT_FILE"
            [[ -e ''${ENCRYPTED_FILE} ]] && rm "$ENCRYPTED_FILE"
        }; trap "cleanup" EXIT

        if [[ -e "$FILE" ]]; then
            ${envPath} ${pkgs.rage}/bin/rage -d ${masterIdentityArgs} -o "$CLEARTEXT_FILE" "$FILE" \
                || die "Failed to decrypt file. Aborting."
        fi
        shasum_before="$(sha512sum "$CLEARTEXT_FILE")"

        $EDITOR "$CLEARTEXT_FILE" \
            || die "Editor returned unsuccessful exit status. Aborting, original is left unchanged."

        shasum_after="$(sha512sum "$CLEARTEXT_FILE")"
        if [[ "$shasum_before" == "$shasum_after" ]]; then
            echo "No content changes, original is left unchanged."
            exit 0
        fi

        ${envPath} ${pkgs.rage}/bin/rage -e ${masterIdentityArgs} -o "$ENCRYPTED_FILE" "$CLEARTEXT_FILE" \
            || die "Failed to (re)encrypt edited file, original is left unchanged."
        cp --no-preserve=all "$ENCRYPTED_FILE" "$FILE" # cp instead of mv preserves original attributes and permissions

        exit 0
      '';
  };
}
