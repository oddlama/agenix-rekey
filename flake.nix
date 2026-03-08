{
  inputs = {
    flake-compat = {
     url = "github:NixOS/flake-compat";
     flake = false;
    };
    devshell = {
      url = "github:numtide/devshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    let
      allApps = [
        "edit-view"
        "generate"
        "rekey"
        "update-masterkeys"
      ];
    in
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.devshell.flakeModule
        inputs.flake-compat.flakeModule
        inputs.flake-parts.flakeModules.easyOverlay
        inputs.flake-parts.flakeModules.flakeModules
        inputs.pre-commit-hooks.flakeModule
        inputs.treefmt-nix.flakeModule
      ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      flake =
        {
          config,
          lib,
          ...
        }:
        {
          flakeModule = ./flake-module.nix;
          nixosModules = {
            agenix-rekey = import ./modules/agenix-rekey.nix inputs.nixpkgs;
            agenixRekey = config.nixosModules.agenix-rekey; # backward compat
            default = config.nixosModules.agenix-rekey;
          };
          darwinModules = {
            agenix-rekey = import ./modules/agenix-rekey.nix inputs.nixpkgs;
            default = config.darwinModules.agenix-rekey;
          };
          homeManagerModules = {
            agenix-rekey = import ./modules/agenix-rekey.nix inputs.nixpkgs;
            default = config.homeManagerModules.agenix-rekey;
          };

          configure =
            {
              # The path of the user's flake. Needed to run a sandbox-relaxed
              # app that saves the rekeyed outputs.
              userFlake,
              # Configurations where agenix-rekey will search for attributes
              nixosConfigurations ? { },
              darwinConfigurations ? { },
              homeConfigurations ? { },
              collectHomeManagerConfigurations ? true,
              # Legacy alias for nixosConfigurations see https://github.com/oddlama/agenix-rekey/pull/51
              nodes ? { },
              # The package sets to use. pkgs.${system} must yield an initialized nixpkgs package set
              pkgs ? pkgs,
              # A function that returns the age package given a package set. Use
              # this to override which tools is used for encrypting / decrypting.
              # Defaults to rage (pkgs.rage). We only guarantee compatibility for
              # pkgs.age and pkgs.rage.
              agePackage ? (p: p.rage),
              # The systems to generate apps for
              systems ? [
                "x86_64-linux"
                "aarch64-linux"
                "x86_64-darwin"
                "aarch64-darwin"
              ],
            }:
            lib.genAttrs systems (
              system:
              let
                pkgs' = import inputs.nixpkgs {
                  inherit system;
                };
              in
              lib.genAttrs allApps (
                app:
                import ./apps/${app}.nix {
                  nodes = import ./nix/select-nodes.nix {
                    inherit
                      nodes
                      nixosConfigurations
                      darwinConfigurations
                      homeConfigurations
                      collectHomeManagerConfigurations
                      ;
                    inherit (pkgs') lib;
                  };
                  inherit userFlake agePackage;
                  pkgs = pkgs';
                }
              )
            );
        };

      perSystem =
        {
          config,
          pkgs,
          ...
        }:
        {
          devshells.default = {
            packages = [
              config.treefmt.build.wrapper
            ];
            devshell.startup.pre-commit.text = config.pre-commit.installationScript;
          };

          pre-commit.settings.hooks.treefmt.enable = true;
          treefmt = {
            projectRootFile = "flake.nix";
            programs = {
              deadnix.enable = true;
              statix.enable = true;
              nixfmt.enable = true;
              rustfmt.enable = true;
            };
          };

          packages.default = pkgs.callPackage ./nix/package.nix {
            inherit allApps;
          };
          overlayAttrs.agenix-rekey = config.packages.default;
        };
    };
}
