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
          echo "Rekeying ${secretName} for host ${hostName}"
          ${envPath} ${pkgs.rage}/bin/rage ${masterIdentityArgs} -d ${secretAttrs.file} \
            | ${envPath} ${pkgs.rage}/bin/rage -r "${hostPubkey}" -o "${secretOut}" -e \
            || { \
              echo "[1;31mFailed to rekey secret ${secretName} for ${hostName}![m" ; \
              echo "This is a dummy replacement value. The actual secret could not be rekeyed." \
                | ${envPath} ${pkgs.rage}/bin/rage -r "${hostPubkey}" -o "${secretOut}" -e ; \
            }
        '';
      in ''
        # Remove old rekeyed secrets
        test -e "${tmpSecretsDir}" && rm -r "${tmpSecretsDir}"
        mkdir -p "${tmpSecretsDir}"

        # Rekey secrets for this host
        ${concatStringsSep "\n" (mapAttrsToList rekeyCommand secrets)}
        echo "${rekeyedSecrets.personality}" > "${tmpSecretsDir}/personality"
      '';
    in
      pkgs.writeShellScript "rekey" ''
        set -euo pipefail
        ${concatStringsSep "\n" (mapAttrsToList rekeyCommandsForHost self.nixosConfigurations)}
        # Pivot to another script that has /tmp available in its sandbox
        nix run --extra-sandbox-paths /tmp "${self.outPath}#rekey-save-outputs";
      '';
  };
  rekey-save-outputs = mkApp {
    drv = let
      copyHostSecrets = hostName: hostAttrs: let
        rekeyedSecrets = import ../nix/output-derivation.nix pkgs hostAttrs.config;
      in ''echo "Stored rekeyed secrets for ${hostAttrs.config.networking.hostName} in ${rekeyedSecrets}"'';
    in
      pkgs.writeShellScript "rekey-save-outputs" ''
        set -euo pipefail
        ${concatStringsSep "\n" (mapAttrsToList copyHostSecrets self.nixosConfigurations)}
      '';
  };
}
