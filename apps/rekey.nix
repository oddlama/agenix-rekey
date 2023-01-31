{
  self,
  nixpkgs,
  flake-utils,
  ...
}: system:
with nixpkgs.lib;
with flake-utils.lib; let
  pkgs = import nixpkgs {inherit system;};
in rec {
  rekey = mkApp {
    drv = let
      rekeyCommandsForHost = hostName: hostAttrs: let
        rekeyedSecrets = import ../nix/output-derivation.nix pkgs hostAttrs.config;
        inherit (rekeyedSecrets) tmpSecretsDir;
        inherit (hostAttrs.config.rekey) agePlugins hostPubkey masterIdentityPaths secrets;

        # Collect paths to enabled age plugins for this host
        envPath = ''PATH="$PATH${concatMapStrings (x: ":${x}/bin") agePlugins}"'';
        masterIdentityArgs = concatMapStrings (x: ''-i "${x}" '') masterIdentityPaths;
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

        ${concatStringsSep "\n" (mapAttrsToList rekeyCommandsForHost self.nixosConfigurations)}
        # Pivot to another script that has /tmp available in its sandbox
        nix run --extra-sandbox-paths /tmp "${self.outPath}#rekey-save-outputs";
      '';
  };
  rekey-save-outputs = mkApp {
    drv = let
      copyHostSecrets = hostName: hostAttrs: let
        rekeyedSecrets = import ../nix/output-derivation.nix pkgs hostAttrs.config;
      in ''echo "Stored rekeyed secrets for ${hostAttrs.config.networking.hostName} in ${rekeyedSecrets.drv}"'';
    in
      pkgs.writeShellScriptBin "rekey-save-outputs" ''
        set -euo pipefail
        ${concatStringsSep "\n" (mapAttrsToList copyHostSecrets self.nixosConfigurations)}
      '';
  };
}
