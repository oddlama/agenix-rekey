{
  description = "An agenix extension to facilitate using a Yubikey/master-identity by automating per-host secret rekeying";
  outputs = {
    self,
    flake-utils,
    ...
  }: {
    nixosModules.agenixRekey = import ./modules/agenix-rekey.nix;
    nixosModules.default = self.nixosModules.agenixRekey;
    defineApps = import ./apps/rekey.nix;
  };
}
