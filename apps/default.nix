{
  # The path of the user's flake. Needed to run a sandbox-relaxed
  # app that saves the rekeyed outputs.
  userFlake,
  # The package set of the machine running these apps
  pkgs,
  # All nixos definitions that should be considered for rekeying
  nodes,
}: let
  args = {
    inherit userFlake pkgs nodes;
    inherit (pkgs) lib;
  };
in {
  edit-secret = {
    type = "app";
    program = toString (import ./edit-secret.nix args);
  };
  rekey = {
    type = "app";
    program = toString (import ./rekey.nix args);
  };
  generate-secrets = {
    type = "app";
    program = toString (import ./generate-secrets.nix args);
  };
}
