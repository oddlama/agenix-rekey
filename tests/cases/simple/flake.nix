{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-lib.url = "github:nix-community/nixpkgs.lib";
    darwin = {
      url = "github:lnl7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    systems.url = "github:nix-systems/default";
    flake-utils = {
      url = "github:numtide/flake-utils";
      inputs.systems.follows = "systems";
    };
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs-lib";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.darwin.follows = "darwin";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
      inputs.systems.follows = "systems";
    };
    devshell = {
      url = "github:numtide/devshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix-rekey = {
      url = "github:oddlama/agenix-rekey";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.treefmt-nix.follows = "treefmt";
      inputs.pre-commit-hooks.follows = "pre-commit-hooks";
      inputs.devshell.follows = "devshell";
      inputs.flake-parts.follows = "flake-parts";
    };
  };

  outputs =
    { self, ... }@inputs:
    {
      # A simple nixos host which uses one secret
      nixosConfigurations.host = inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          inputs.agenix.nixosModules.default
          inputs.agenix-rekey.nixosModules.default

          # configuration.nix
          (
            { config, ... }:
            {
              services.openssh.enable = true;
              age.rekey = {
                hostPubkey = ./host.pub;
                masterIdentities = [ ./key.txt ];
                storageMode = "local";
                localStorageDir = ./. + "/secrets/rekeyed/${config.networking.hostName}";
              };

              age.secrets.secret.rekeyFile = ./secret.age;
            }
          )
        ];
      };

      agenix-rekey = inputs.agenix-rekey.configure {
        userFlake = self;
        inherit (self) nixosConfigurations;
      };
    }
    // inputs.flake-utils.lib.eachDefaultSystem (system: rec {
      # Create a pkgs with the agenix-rekey overlay so we have access to `pkgs.agenix-rekey` later
      pkgs = import inputs.nixpkgs {
        inherit system;
        overlays = [ inputs.agenix-rekey.overlays.default ];
      };
      packages.agenix = pkgs.agenix-rekey;

      # Add agenix-rekey to your devshell, so you can use the `agenix rekey` command
      devShells.default = pkgs.mkShell {
        packages = [ pkgs.agenix-rekey ];
      };
    });
}
