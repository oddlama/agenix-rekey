{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
    agenix-rekey.url = "github:oddlama/agenix-rekey";
    agenix-rekey.inputs.nixpkgs.follows = "nixpkgs";
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
      ];

      flake = {
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
      };

      perSystem =
        {
          config,
          pkgs,
          ...
        }:
        {
          # Tell agenix-rekey which hosts to consider
          agenix-rekey.nixosConfigurations = inputs.self.nixosConfigurations;

          # Add agenix-rekey to your devshell, so you can use the `agenix rekey` command
          devShells.default = pkgs.mkShell {
            nativeBuildInputs = [
              config.agenix-rekey.package
            ];

            # Automatically adds rekeyed secrets to git without
            # requiring `agenix rekey -a`.
            env.AGENIX_REKEY_ADD_TO_GIT = true;
          };
        };
    };
}
