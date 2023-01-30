{
  description = "An agenix extension to facilitate Yubikey/master-identity use by automating per-host secret rekeying";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.agenix = {
    url = "github:ryantm/agenix";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = { self, flake-utils, ... } @ inputs: {
    nixosModules.agenixRekey = import ./modules/agenix-rekey.nix;
    nixosModules.default = self.nixosModules.agenixRekey;
  } // flake-utils.eachSystem flake-utils.allSystems (system: {
	apps = import ./apps/rekey.nix inputs system;
  });
}
