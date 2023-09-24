{
  inputs = {
    devshell = {
      url = "github:numtide/devshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  description = "An agenix extension adding secret generation and automatic rekeying using a YubiKey or master-identity";
  outputs = {
    self,
    nixpkgs,
    flake-utils,
    devshell,
    pre-commit-hooks,
    ...
  }: let
    allApps = ["edit" "regenerate" "rekey"];
  in {
    nixosModules.agenixRekey = import ./modules/agenix-rekey.nix nixpkgs;
    nixosModules.default = self.nixosModules.agenixRekey;

    configure = userArgs: flake-utils.lib.eachDefaultSystem (system: let
      pkgs = self.pkgs.${system};
      args = userArgs // { inherit pkgs; };
    in {
      apps = pkgs.lib.genAttrs allApps
        (app: import ./apps/${app}.nix args);
    });

    # XXX: deprecated, scheduled for removal in 2024. Use the package instead of
    # defining apps. This is just a compatibility wrapper that defines apps with
    # the same interface as before.
    defineApps = argsOrSelf: pkgs: nodes:
      pkgs.lib.warn ''
        The `agenix-rekey.defineApps self pkgs nodes` function is deprecated and will be removed in 2024.
        The new approach will unclutter your flake's app definitions and provide a hermetic entrypoint for
        agenix-rekey, which can be accessed more egonomically via a new CLI wrapper 'agenix' - or alternatively
        via `nix run .#agenix-rekey.apps.$system.<app>` in case you want to integrate it into your own scripts.

        Please remove your current agenix-rekey.defineApps call entirely and instead add a new top-level
        output `agenix-rekey = { userFlake = self; nodes = self.nixosSystems };`. The new wrapper CLI can
        be accessed by adding `agenix-rekey.packages.default` to your devshell. For more information,
        please visit the github page and refer to the updated README.''
        (import ./apps) {
          userFlake = argsOrSelf; # argsOrSelf = self
          inherit pkgs nodes;
        };
  } // flake-utils.lib.eachDefaultSystem (system: rec {
    pkgs = import nixpkgs { inherit system; };

    # `nix build`
    packages.default = packages.agenix-rekey;
    # `nix build .#agenix-rekey`
    packages.agenix-rekey = pkgs.callPackage ./nix/package.nix {
      inherit allApps;
    };

    # `nix run`
    apps.default = flake-utils.lib.mkApp {drv = packages.agenix-rekey;};
  });
}
