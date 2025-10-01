{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-lib.url = "github:nix-community/nixpkgs.lib";
    darwin = {
      url = "github:lnl7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    systems.url = "github:nix-systems/default";
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
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.agenix-rekey.flakeModule
      ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      flake = {
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
      };

      perSystem =
        {
          config,
          ...
        }:
        {
          # Tell agenix-rekey which hosts to consider
          agenix-rekey.nixosConfigurations = inputs.self.nixosConfigurations;

          # Not actually needed we just need it for tests
          packages.agenix = config.agenix-rekey.package;
        };
    };
}
