{
  pkgs,
  nodes,
  mode,
  ...
}: let
  inherit (pkgs.lib) mapAttrsToList mapAttrs' nameValuePair fold hasAttrByPath;
  findHomeManagerForHost = hostName: hostCfg:
    if (hasAttrByPath ["config" "home-manager" "users"] hostCfg)
    then (mapAttrs' (name: value: nameValuePair "host-${hostName}-user-${name}" {config = value;}) hostCfg.config.home-manager.users)
    else {};
  listNodesWithHomeManager = mapAttrsToList findHomeManagerForHost nodes;
  combineNodes = x: y: x // y;
  homeManagerNodes = fold combineNodes {} listNodesWithHomeManager;
  enabledNodes = rec {
    nixos = nodes;
    home-manager = homeManagerNodes;
    all = nixos // home-manager;
  };
in
  enabledNodes.${mode}
