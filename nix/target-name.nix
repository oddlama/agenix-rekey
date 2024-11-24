{config}: let
  isNixosConfiguration = config ? networking.hostName;
in
  if isNixosConfiguration
  then config.networking.hostName
  else config.home.username
