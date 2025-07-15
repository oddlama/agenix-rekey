/*
  A module to import into flakes based on flake-parts.
  Makes integration into a flake easy and tidy.
  See https://flake.parts, https://flake.parts/options/agenix-rekey
*/
{
  lib,
  self,
  config,
  flake-parts-lib,
  ...
}:
let
  inherit (lib)
    mkOption
    mkPackageOption
    types
    ;

  allApps = [
    "edit"
    "generate"
    "rekey"
    "update-masterkeys"
  ];
in
{
  options = {
    flake = flake-parts-lib.mkSubmoduleOptions {
      agenix-rekey = mkOption {
        type = types.lazyAttrsOf (types.lazyAttrsOf types.package);
        default = lib.mapAttrs (
          _system: config':
          lib.genAttrs allApps (
            app:
            import ./apps/${app}.nix {
              nodes = import ./nix/select-nodes.nix {
                inherit (config'.agenix-rekey)
                  nixosConfigurations
                  homeConfigurations
                  collectHomeManagerConfigurations
                  ;
                inherit (config'.agenix-rekey.pkgs) lib;
              };
              inherit (config'.agenix-rekey) pkgs;
              agePackage = _: config'.agenix-rekey.agePackage;
              userFlake = self;
            }
          )
        ) config.allSystems;
        defaultText = "Automatically filled by agenix-rekey";
        readOnly = true;
        description = ''
          The agenix-rekey apps specific to your flake. Used by the `agenix` wrapper script,
          and can be run manually using `nix run .#agenix-rekey.$system.<app>`.
        '';
      };
    };

    perSystem = flake-parts-lib.mkPerSystemOption (
      {
        config,
        lib,
        pkgs,
        ...
      }:
      {
        imports = [
          (lib.mkRenamedOptionModule
            [
              "agenix-rekey"
              "nodes"
            ]
            [
              "agenix-rekey"
              "nixosConfigurations"
            ]
          )
        ];

        options.agenix-rekey = {
          nixosConfigurations = mkOption {
            type = types.lazyAttrsOf types.unspecified;
            description = "All nixosSystems that should be considered for rekeying.";
            default = lib.filterAttrs (_: x: x.config ? age) self.nixosConfigurations;
            defaultText = lib.literalExpression "lib.filterAttrs (_: x: x.config ? age) self.nixosConfigurations";
          };

          homeConfigurations = mkOption {
            type = types.lazyAttrsOf types.unspecified;
            description = "All home manager configurations that should be considered for rekeying.";
            default = lib.filterAttrs (_: x: x.config ? age) (self.homeConfigurations or { });
            defaultText = lib.literalExpression "lib.filterAttrs (_: x: x.config ? age) (self.homeConfigurations or { })";
          };

          collectHomeManagerConfigurations = mkOption {
            type = types.bool;
            description = "Whether to collect home manager configurations automatically from specified NixOS configurations.";
            default = true;
          };

          pkgs = mkOption {
            type = types.unspecified;
            description = "The package set to use when defining agenix-rekey scripts.";
            default = pkgs;
            defaultText = lib.literalExpression "pkgs # (module argument)";
          };

          agePackage = mkPackageOption config.agenix-rekey.pkgs "rage" {
            extraDescription = ''
              Determines the age package used for encrypting / decrypting.
              Defaults to `pkgs.rage`. We only guarantee compatibility with
              `pkgs.age` and `pkgs.rage`.
            '';
          };

          package = mkOption {
            type = types.package;
            default = config.agenix-rekey.pkgs.callPackage ./nix/package.nix {
              inherit allApps;
            };
            defaultText = "<agenix script derivation from agenix-rekey>";
            readOnly = true;
            description = ''
              The agenix-rekey wrapper script `agenix`.
              We recommend adding this to your devshell so you can execute it easily.
              By using the package provided here, you can skip adding the overlay to your pkgs.
              Alternatively you can also pass it to your flake outputs (apps or packages).
            '';
          };
        };
      }
    );
  };
}
