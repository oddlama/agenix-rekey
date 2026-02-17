{
  lib,
  nodes ? { },
  nixosConfigurations,
  darwinConfigurations,
  homeConfigurations,
  collectHomeManagerConfigurations,
  ...
}:
let
  inherit (lib)
    assertMsg
    attrNames
    concatStringsSep
    intersectLists
    mapAttrsToList
    mapAttrs'
    nameValuePair
    foldl'
    optionalAttrs
    filterAttrs
    ;

  effectiveNixosConfigurations =
    (lib.warnIf (nodes != { }) ''
      The `nodes` parameter in `agenix-rekey.configure` has been
      renamed to `nixosConfigurations`. Please change your invocation to
      use the new parameter name.

      There is also a new `homeConfigurations` parameter that allows stand-alone
      usage of home-manager without a host module. Otherwise, if you are using
      home-manager through its NixOS or darwin module, your home-manager
      configurations will be detected automatically.
    '' nodes)
    // nixosConfigurations;

  prefixHosts =
    prefix: hosts: mapAttrs' (hostName: hostCfg: nameValuePair "${prefix}:${hostName}" hostCfg) hosts;

  prefixedNixosConfigurations = prefixHosts "nixos" effectiveNixosConfigurations;
  prefixedDarwinConfigurations = prefixHosts "darwin" darwinConfigurations;

  findHomeManagerForHost =
    hostName: hostCfg:
    if (hostCfg ? config.home-manager.users) then
      mapAttrs' (name: value: nameValuePair "host-${hostName}-user-${name}" { config = value; }) (
        filterAttrs (_: value: value ? age.rekey) hostCfg.config.home-manager.users
      )
    else
      { };

  effectiveHostConfigurations = prefixedNixosConfigurations // prefixedDarwinConfigurations;
  listHostConfigsWithHomeManager = mapAttrsToList findHomeManagerForHost effectiveHostConfigurations;
  hmConfigsInsideHostConfiguration = foldl' lib.mergeAttrs { } listHostConfigsWithHomeManager;

  overlappingKeys = left: right: intersectLists (attrNames left) (attrNames right);
  assertNoOverlappingKeys =
    enabled: leftName: rightName: left: right:
    let
      overlaps = overlappingKeys left right;
    in
    assertMsg (!enabled || overlaps == [ ]) ''
      Found duplicate node keys between ${leftName} and ${rightName}: ${concatStringsSep ", " overlaps}
      Please rename one side to avoid collisions.
    '';
in
assert assertNoOverlappingKeys true "host configurations" "homeConfigurations"
  effectiveHostConfigurations
  homeConfigurations;
assert assertNoOverlappingKeys collectHomeManagerConfigurations "host configurations"
  "auto-collected home-manager configurations"
  effectiveHostConfigurations
  hmConfigsInsideHostConfiguration;
assert assertNoOverlappingKeys collectHomeManagerConfigurations
  "auto-collected home-manager configurations"
  "homeConfigurations"
  hmConfigsInsideHostConfiguration
  homeConfigurations;
effectiveHostConfigurations
// homeConfigurations
// optionalAttrs collectHomeManagerConfigurations hmConfigsInsideHostConfiguration
