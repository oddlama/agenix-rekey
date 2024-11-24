{
  lib,
  nodes,
  nixosConfigurations,
  homeConfigurations,
  collectHomeManagerConfigurations,
  ...
}: let
  inherit (lib) mapAttrsToList mapAttrs' nameValuePair foldl' optionalAttrs;
  effectiveNixosConfigurations = nodes // nixosConfigurations; # include legacy parameter
  findHomeManagerForHost = hostName: hostCfg:
    if (hostCfg ? config.home-manager.users)
    then (mapAttrs' (name: value: nameValuePair "host-${hostName}-user-${name}" {config = value;}) hostCfg.config.home-manager.users)
    else {};
  listNixosConfigsWithHomeManager = mapAttrsToList findHomeManagerForHost effectiveNixosConfigurations;
  mergeAttrs = x: y: x // y;
  hmConfigsInsideNixosConfiguration = foldl' mergeAttrs {} listNixosConfigsWithHomeManager;
in
  effectiveNixosConfigurations // homeConfigurations // optionalAttrs collectHomeManagerConfigurations hmConfigsInsideNixosConfiguration
