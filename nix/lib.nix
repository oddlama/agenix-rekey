{
  userFlake,
  pkgs,
  nodes,
  agePackage,
  ...
}: let
  inherit
    (pkgs.lib)
    catAttrs
    concatLists
    concatMapStrings
    concatStringsSep
    escapeShellArg
    filter
    getExe
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
  toIdentityArgs = identities:
    concatStringsSep " " (map (x: "-i ${escapeShellArg x.identity}") identities);

  ageProgram = getExe (agePackage pkgs);
  # Collect all paths to enabled age plugins
  envPath = ''PATH="$PATH"${concatMapStrings (x: ":${escapeShellArg x}/bin") mergedAgePlugins}'';
  # Master identities that have no explicit pubkey specified
  masterIdentitiesNoPubkey = filter (x: x.pubkey == null) mergedMasterIdentities;
  # Explicitly specified recipients, containing both the explicit master pubkeys as well as the extra pubkeys
  extraEncryptionPubkeys = filter (x: x != null) (catAttrs "pubkey" mergedMasterIdentities) ++ mergedExtraEncryptionPubkeys;

  # Skip master identities with pubkeys during encryption
  encryptionMasterIdentityArgs = toIdentityArgs masterIdentitiesNoPubkey;
  extraEncryptionPubkeyArgs = concatStringsSep " " (map pubkeyOpt extraEncryptionPubkeys);
  # For decryption, we require access to all master identities
  decryptionMasterIdentityArgs = toIdentityArgs mergedMasterIdentities;
in {
  userFlakeDir = toString userFlake.outPath;
  inherit mergedSecrets;

  # Premade shell commands to encrypt and decrypt secrets
  ageMasterEncrypt = "${envPath} ${ageProgram} -e ${encryptionMasterIdentityArgs} ${extraEncryptionPubkeyArgs}";
  ageMasterDecrypt = "${envPath} ${ageProgram} -d ${decryptionMasterIdentityArgs}";
  ageHostEncrypt = hostAttrs: let
    hostPubkey = removeSuffix "\n" hostAttrs.config.age.rekey.hostPubkey;
  in "${envPath} ${ageProgram} -e ${pubkeyOpt hostPubkey}";
}
