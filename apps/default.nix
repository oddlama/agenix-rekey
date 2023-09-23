let
  defineApps = args @ {
    # The path of the user's flake. Needed to run a sandbox-relaxed
    # app that saves the rekeyed outputs.
    userFlake,
    # The package set of the machin running these apps
    pkgs,
    # All nixos definitions that should be considered for rekeying
    nixosConfigurations,
  }: let
    inherit
      (pkgs.lib)
      flip
      nameValuePair
      removeSuffix
      ;
    mkApp = drv: {
      type = "app";
      program = "${drv}";
    };
    args = {
      inherit userFlake pkgs nixosConfigurations;
      inherit (pkgs) lib;
    };
    apps = [
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
    ));
in
# compatibility wrapper that converts old syntax and issues a deprecation warning
argsOrSelf:
  if argsOrSelf ? userFlake
    then defineApps argsOrSelf # argsOrSelf = args
    else pkgs: nixosConfigurations: pkgs.lib.warn ''
      The syntax `agenix-rekey.defineApps self pkgs nixosConfigurations` has been deprecated and will be removed in the future (around the release of nixos 24.11).
      Please rewrite this to the new syntax which allows for optional arguments:
        agenix-rekey.defineApps {
          userFlake = self;
          inherit pkgs nixosConfigurations;
        }''
      defineApps {
        userFlake = argsOrSelf; # argsOrSelf = self
        inherit pkgs nixosConfigurations;
      }
