{ userFlakePath, app, ... }: let
  # A package set for the host running this script
  system = builtins.currentSystem;
  pkgs = import (userFlake.inputs.nixpkgs or <nixpkgs>) { inherit system; };
  # The user's flake that utilizes agenix-rekey.
  userFlake = builtins.getFlake (toString userFlakePath);
  # Arguments to the actual app
  args =  {
    inherit userFlake pkgs;
    inherit (pkgs) lib;
  } // userFlake.agenix-rekey;
in import app args
