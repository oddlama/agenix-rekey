{
  pkgs,
  config,
}: let
  inherit (pkgs.lib) hasAttrByPath;
  isNixosConfiguration = hasAttrByPath ["networking" "hostName"] config;
in
  if isNixosConfiguration
  then config.networking.hostName
  else config.home.username
