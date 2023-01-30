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

        # Enable selected age plugins for this host
        envPath = ''PATH="$PATH${concatMapStrings (x: ":${x}/bin") hostAttrs.config.rekey.agePlugins}"'';
        rekeyCommand = secretName: secretAttrs: let
          masterIdentityArgs = concatMapStrings (x: ''-i "${x}" '') hostAttrs.config.rekey.masterIdentityPaths;
          secretOut = "${tmpSecretsDir}/${secretName}.age";
        in ''
          echo "Rekeying ${secretName} for host ${hostName}"
          ${envPath} ${pkgs.rage}/bin/rage ${masterIdentityArgs} -d ${secretAttrs.file} \
            | ${envPath} ${pkgs.rage}/bin/rage -r "${hostPubkeyStr}" -o "${secretOut}" -e \
            || { \
              echo "[1;31mFailed to rekey secret ${secretName} for ${hostName}![m" ; \
              echo "This is a dummy replacement value. The actual secret could not be rekeyed." \
                | ${envPath} ${pkgs.rage}/bin/rage -r "${hostPubkeyStr}" -o "${secretOut}" -e ; \
            }
        '';
      in ''
        # Remove old rekeyed secrets
        test -e "${tmpSecretsDir}" && rm -r "${tmpSecretsDir}"
        mkdir -p "${tmpSecretsDir}"

        # Rekey secrets for this host
        ${concatStringsSep "\n" (mapAttrsToList rekeyCommand hostAttrs.config.rekey.secrets)}
        echo "${rekeyedSecrets.personality}" > "${tmpSecretsDir}/personality"
      '';
    in
      pkgs.writeShellScript "rekey" ''
        set -euo pipefail
        ${concatStringsSep "\n" (mapAttrsToList rekeyCommandsForHost self.nixosConfigurations)}
        nix run --extra-sandbox-paths /tmp "${../.}#rekey-save-outputs";
      '';
  };
  rekey-save-outputs = mkApp {
    drv = let
      copyHostSecrets = hostName: hostAttrs: let
        drv = import ../nix/output-derivation.nix pkgs hostAttrs.config;
      in ''echo "Stored rekeyed secrets for ${hostAttrs.config.networking.hostName} in ${drv}"'';
    in
      pkgs.writeShellScript "rekey-save-outputs" ''
        set -euo pipefail
        ${concatStringsSep "\n" (mapAttrsToList copyHostSecrets self.nixosConfigurations)}
      '';
  };
}
