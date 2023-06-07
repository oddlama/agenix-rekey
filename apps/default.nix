self: appHostPkgs: nixosConfigurations: let
  inherit
    (appHostPkgs.lib)
    flip
    nameValuePair
    removeSuffix
    ;
  mkApp = drv: {
    type = "app";
    program = "${drv}";
  };
  args = {
    inherit self nixosConfigurations;
    inherit (appHostPkgs) lib;
    pkgs = appHostPkgs;
  };
  apps = [
    ./_rekey-save-output.nix
    ./rekey.nix
    ./edit-secret.nix
  ];
in
  builtins.listToAttrs (flip map apps (
    appPath:
      nameValuePair
      (removeSuffix ".nix" (builtins.baseNameOf appPath))
      (mkApp (import appPath args))
  ))
