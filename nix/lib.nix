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

  extraEncryptionPubkeyArgs = concatStringsSep " " (map pubkeyOpt extraEncryptionPubkeys);
  # For decryption, we require access to all master identities
  decryptionMasterIdentityArgs = toIdentityArgs mergedMasterIdentities;
in {
  userFlakeDir = toString userFlake.outPath;
  inherit mergedSecrets;

  # Premade shell commands to encrypt and decrypt secrets.
  # NOTE: In order to keep compatibility with existing generator setups,
  # any command here must be directly compatible with the (r)age CLI.
  # Therefore, any shellscript must pass "$@" to `ageProgram`,
  # while packaged scripts must be unwrapped, e.g. like so:
  # ```
  # "${
  #   pkgs.writeShellApplication {
  #     name = "<name>";
  #     ...
  #   }
  # }/bin/<name>"
  # ```.
  # Furthermore, warnings and other notifications should be deferred to stderr,
  # as to not interfere with generator setups that use stdin and stdout to pass data through (r)age.
  ageMasterEncrypt = let
    name = "encrypt";
    encryptWrapper = pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = with pkgs; [coreutils gnugrep];
      text = ''
        # Redirect warnings to stderr.
        warn() { echo "warning:" "$@" >&2; }

        # Collect final identity arguments in an array.
        masterIdentityArgs=()
        for file in ${
          # Skip master identities with explicit pubkeys, since they are added separately.
          concatStringsSep " " (map (x: "${escapeShellArg x.identity}") masterIdentitiesNoPubkey)
        }; do
          # Keep track if a file was processed.
          file_processed=false

          # Only consider files that contain exactly one identity, since files with multiple identities are allowed,
          # but are ambiguous with respect to the pairings between identities and pubkeys.
          if [[ $(grep -o "^AGE-" "$file" | wc -l) == 1 ]]; then
            if grep -q "^AGE-PLUGIN-YUBIKEY-" "$file"; then
              # If the file specifies "Recipient: age1yubikey1<pubkey>", extract recipient and specify with "-r".
              if mapfile -t pubkeys < <(grep 'Recipient: age1yubikey1' "$file" | grep -Eoh 'age1yubikey1[0-9a-z]+'); then
                warn_pubkey_multiple=false
                if [[ ''${#pubkeys[@]} -gt 1 ]]; then
                  warn_pubkey_multiple=true
                fi

                if [[ "$warn_pubkey_multiple" == true ]]; then
                  warn "$file"
                  warn "Found more than one public key, encrypting to all of them."
                  warn "If this is not intended, please remove the \"Recipient: \" in front of one of the two keys."
                  warn "Alternatively, override the public key in config.age.rekey.masterIdentities."
                  warn "List of public keys found:"
                fi
                for pubkey in "''${pubkeys[@]}"; do
                  if [[ "$warn_pubkey_multiple" == true ]]; then
                    warn "  $pubkey"
                  fi
                  masterIdentityArgs+=("-r" "$pubkey")
                  file_processed=true
                done
              fi
            fi
          fi

          # If the identity was not processed at this point, pass it to (r)age as a regular identity file,
          # so that the program can decide what to do with it.
          if [[ "$file_processed" == false ]]; then
            masterIdentityArgs+=("-i" "$file")
          fi
        done
        ${envPath} ${ageProgram} -e "''${masterIdentityArgs[@]}" ${extraEncryptionPubkeyArgs} "$@"
      '';
    };
  in "${encryptWrapper}/bin/${name}";
  ageMasterDecrypt = let
    name = "decrypt";
    decryptWrapper = pkgs.writeShellApplication {
      inherit name;
      text = ''
        ${envPath} ${ageProgram} -d ${decryptionMasterIdentityArgs} "$@"
      '';
    };
  in "${decryptWrapper}/bin/${name}";
  ageHostEncrypt = hostAttrs: let
    hostPubkey = removeSuffix "\n" hostAttrs.config.age.rekey.hostPubkey;
  in "${envPath} ${ageProgram} -e ${pubkeyOpt hostPubkey}";
}
