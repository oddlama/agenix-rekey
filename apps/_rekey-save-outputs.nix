{
  lib,
  pkgs,
  nixosConfigurations,
  ...
}: let
  inherit
    (lib)
    concatStringsSep
    mapAttrsToList
    ;

  copyHostSecrets = hostName: hostAttrs: let
    rekeyedSecrets = import ../nix/output-derivation.nix {
      appHostPkgs = pkgs;
      hostConfig = hostAttrs.config;
    };
  in ''echo "Stored rekeyed secrets for ${hostAttrs.config.networking.hostName} in ${rekeyedSecrets.drv}"'';
in
  pkgs.writeShellScript "_rekey-save-outputs" ''
    set -euo pipefail
    ${concatStringsSep "\n" (mapAttrsToList copyHostSecrets nixosConfigurations)}
  ''
