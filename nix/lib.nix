{
  userFlake,
  lib,
  pkgs,
  nodes,
  ...
}: let
  inherit
    (lib)
    concatLists
    concatMapStrings
    concatStringsSep
    escapeShellArg
    filter
    mapAttrsToList
    removeSuffix
    substring
    unique
    ;

  # Collect rekeying options from all hosts
  mergeArray = f: unique (concatLists (mapAttrsToList (_: f) nodes));
  mergedAgePlugins = mergeArray (x: x.config.age.rekey.agePlugins or []);
  mergedMasterIdentities = mergeArray (x: x.config.age.rekey.masterIdentities or []);
  mergedExtraEncryptionPubkeys = mergeArray (x: x.config.age.rekey.extraEncryptionPubkeys or []);
  mergedSecrets = mergeArray (x: filter (y: y != null) (mapAttrsToList (_: s: s.rekeyFile) x.config.age.secrets));

  isAbsolutePath = x: substring 0 1 x == "/";
  pubkeyOpt = x:
    if isAbsolutePath x
    then "-R ${escapeShellArg x}"
    else "-r ${escapeShellArg x}";

  # Collect all paths to enabled age plugins
  envPath = ''PATH="$PATH"${concatMapStrings (x: ":${escapeShellArg x}/bin") mergedAgePlugins}'';
  # The identities which can decrypt secrets need to be passed to rage
  masterIdentityArgs = concatMapStrings (x: "-i ${escapeShellArg x} ") mergedMasterIdentities;
  # Extra recipients for master encrypted secrets
  extraEncryptionPubkeys = concatStringsSep " " (map pubkeyOpt mergedExtraEncryptionPubkeys);
in {
  userFlakeDir = toString userFlake.outPath;
  inherit mergedSecrets;

  # Premade shell commands to encrypt and decrypt secrets
  rageMasterEncrypt = "${envPath} ${pkgs.rage}/bin/rage -e ${masterIdentityArgs} ${extraEncryptionPubkeys}";
  rageMasterDecrypt = "${envPath} ${pkgs.rage}/bin/rage -d ${masterIdentityArgs}";
  rageHostEncrypt = hostAttrs: let
    hostPubkey = removeSuffix "\n" hostAttrs.config.age.rekey.hostPubkey;
  in "${envPath} ${pkgs.rage}/bin/rage -e ${pubkeyOpt hostPubkey}";
}
