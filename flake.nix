{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  description = "An agenix extension adding secret generation and automatic rekeying using a YubiKey or master-identity";
  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ...
  }: {
    nixosModules.agenixRekey = import ./modules/agenix-rekey.nix nixpkgs;
    nixosModules.default = self.nixosModules.agenixRekey;

    # XXX: deprecated, scheduled for removal in 2024. Use the package instead of
    # defining apps. This is just a compatibility wrapper that defines apps with
    # the same interface as before.
    defineApps = argsOrSelf: pkgs: nodes:
      pkgs.lib.warn ''
        The syntax `agenix-rekey.defineApps self pkgs nodes` has been deprecated and will be removed in 2024.
        Please remove the app definition entirely access agenix-rekey via the new CLI tool, which you can access via agenix-rekey.packages.default
        (add it to your devshell). Refer to the README on github for the new setup instructions.''
        (import ./apps) {
          userFlake = argsOrSelf; # argsOrSelf = self
          inherit pkgs nodes;
        };
  } // flake-utils.lib.eachDefaultSystem (system: rec {
    pkgs = import nixpkgs { inherit system; };

    # `nix build`
    packages.default = packages.agenix-rekey;
    # `nix build .#agenix-rekey`
    packages.agenix-rekey = pkgs.callPackage ./nix/package.nix {};

    # `nix run`
    apps.default = flake-utils.lib.mkApp {drv = packages.agenix-rekey;};
  });
}
