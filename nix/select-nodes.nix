{
  lib,
  nodes ? { },
  nixosConfigurations,
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
    concatMapAttrs
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

  # Extract specialisations from an attribute set of `nixosConfigurations` or `homeConfigurations`
  # and add them along side the orignal configurations, using a `renamer` function that gets
  # passed the name of the configuration and the specialisation to generate a new, unique name
  # for each specialisation.
  #
  # Type:
  # ```
  # liftSpecialisationsRenamed :: (String -> String -> String) -> AttrSet -> AttrSet
  # ```
  liftSpecialisationsRenamed =
    renamer:
    concatMapAttrs (
      baseName: baseCfg:
      let
        specialisations = mapAttrs' (
          specName: specCfg:
          nameValuePair (renamer baseName specName)
            # Map specialisation configuration to its own { config = <...> } attrset,
            # analogous to how homeConfigurations are handled further down.
            { config = specCfg.configuration; }
        ) baseCfg.config.specialisation;
      in
      { "${baseName}" = baseCfg; } // specialisations
    );

  nixosConfigurationsWithSpecialisations = liftSpecialisationsRenamed (
    hostName: specName: "${hostName}:${specName}"
  ) effectiveNixosConfigurations;

  homeConfigurationsWithSpecialisations = liftSpecialisationsRenamed (
    homeName: specName: "${homeName}:${specName}"
  ) homeConfigurations;

  findHomeManagerForHost =
    hostName: hostCfg:
    if (hostCfg ? config.home-manager.users) then
      mapAttrs' (name: value: nameValuePair "${hostName}:${name}" { config = value; }) (
        filterAttrs (_: value: value ? age.rekey) hostCfg.config.home-manager.users
      )
    else
      { };

  listNixosConfigsWithHomeManager = mapAttrsToList findHomeManagerForHost nixosConfigurationsWithSpecialisations;
  hmConfigsInsideNixosConfiguration = foldl' lib.mergeAttrs { } listNixosConfigsWithHomeManager;

  # Since `baseName` is derived from `nixosConfigurationsWithSpecialisations`,
  # the names evaluate to "${hostName}:${homeName}:${specName}".
  hmConfigsInsideNixosConfigurationWithSpecialisations = liftSpecialisationsRenamed (
    baseName: specName: "${baseName}:${specName}"
  ) hmConfigsInsideNixosConfiguration;

  # Reduce probability of name collisions.
  nixosConfigurationsRenamed = mapAttrs' (
    n: v: nameValuePair "host: ${n}" v
  ) nixosConfigurationsWithSpecialisations;
  homeConfigurationsRenamed = mapAttrs' (
    n: v: nameValuePair "home: ${n}" v
  ) homeConfigurationsWithSpecialisations;
  hmConfigsRenamed = mapAttrs' (
    n: v: nameValuePair "host+home: ${n}" v
  ) hmConfigsInsideNixosConfigurationWithSpecialisations;

in
nixosConfigurationsRenamed
// homeConfigurationsRenamed
// optionalAttrs collectHomeManagerConfigurations hmConfigsRenamed
