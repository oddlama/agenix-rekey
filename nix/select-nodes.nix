{
  lib,
  nodes ? { },
  nixosConfigurations,
  darwinConfigurations ? { },
  homeConfigurations,
  collectHomeManagerConfigurations,
  ...
}:
let
  inherit (lib)
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
      usage of home-manager without NixOS. Otherwise, if you are using home-manager
      through its NixOS module, your home-manager configurations will be detected
      automatically.
    '' nodes)
    // nixosConfigurations;

  findHomeManagerForHost =
    hostName: hostCfg:
    if (hostCfg ? config.home-manager.users) then
      mapAttrs' (name: value: nameValuePair "host-${hostName}-user-${name}" { config = value; }) (
        filterAttrs (_: value: value ? age.rekey) hostCfg.config.home-manager.users
      )
    else
      { };

  effectiveHostConfigurations = effectiveNixosConfigurations // darwinConfigurations;
  listHostConfigsWithHomeManager = mapAttrsToList findHomeManagerForHost effectiveHostConfigurations;
  hmConfigsInsideHostConfiguration = foldl' lib.mergeAttrs { } listHostConfigsWithHomeManager;
in
effectiveHostConfigurations
// homeConfigurations
// optionalAttrs collectHomeManagerConfigurations hmConfigsInsideHostConfiguration
