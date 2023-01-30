{
  description = "An agenix extension to facilitate using a Yubikey/master-identity by automating per-host secret rekeying";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = {
    self,
    flake-utils,
    ...
  } @ inputs:
    with flake-utils.lib;
      {
        nixosModules.agenixRekey = import ./modules/agenix-rekey.nix;
        nixosModules.default = self.nixosModules.agenixRekey;
      }
      // eachSystem allSystems (system: {
        apps = import ./apps/rekey.nix inputs system;
      });
}
