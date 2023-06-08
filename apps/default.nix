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
    ./edit-secret.nix
    ./generate-secrets.nix
    ./rekey.nix
  ];
in
  builtins.listToAttrs (flip map apps (
    appPath:
      nameValuePair
      (removeSuffix ".nix" (builtins.baseNameOf appPath))
      (mkApp (import appPath args))
  ))
