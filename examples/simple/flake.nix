{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
    agenix-rekey.url = "github:oddlama/agenix-rekey";
    agenix-rekey.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, ... }@inputs:
    {
      # A simple nixos host which uses one secret
      nixosConfigurations.host1 = inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          inputs.agenix.nixosModules.default
          inputs.agenix-rekey.nixosModules.default

          # configuration.nix
          (
            { config, ... }:
            {
              age.rekey = {
                hostPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOy3dC8cCbucumHphroUzZUTKkM0jL3mG3+tkeAWgIdX";
                masterIdentities = [ ./yubikey-identity.pub ];
                storageMode = "local";
                localStorageDir = ./. + "/secrets/rekeyed/${config.networking.hostName}";
              };

              age.secrets.root-pw-hash.rekeyFile = ./root-pw-hash.age;
              users.users.root.hashedPasswordFile = config.age.secrets.root-pw-hash.path;
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

      # Add agenix-rekey to your devshell, so you can use the `agenix rekey` command
      devShells.default = pkgs.mkShell {
        packages = [ pkgs.agenix-rekey ];
        # ...
      };
    });
}
