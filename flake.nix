{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  description = "An agenix extension adding secret generation and automatic rekeying using a YubiKey or master-identity";
  outputs = {
    self,
    nixpkgs,
    ...
  }: {
    nixosModules.agenixRekey = import ./modules/agenix-rekey.nix nixpkgs;
    nixosModules.default = self.nixosModules.agenixRekey;
    defineApps = import ./apps;
  };
}
