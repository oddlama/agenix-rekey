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
  # Explicitly specified recipients, containing both the explicit master pubkeys as well as the extra pubkeys
  extraEncryptionPubkeys = filter (x: x != null) (catAttrs "pubkey" mergedMasterIdentities) ++ mergedExtraEncryptionPubkeys;

  extraEncryptionPubkeyArgs = concatStringsSep " " (map pubkeyOpt extraEncryptionPubkeys);
  # For decryption, we require access to all master identities
  decryptionMasterIdentityArgs = toIdentityArgs mergedMasterIdentities;

  ageWrapperScript = pkgs.writeShellApplication {
    name = "ageWrapper";
    runtimeInputs = with pkgs; [gnugrep];
    text = ''
      # Redirect messages to stderr.
      warn() { echo "warning:" "$@" >&2; }
      error() { echo "error:" "$@" >&2; }

      # Collect identities in a dictionary with mapping:
      # pubkey -> identity file
      declare -A masterIdentityMap
      # Master identities that have a pubkey can be added without further treatment.
      ${
        concatStringsSep "\n"
        (map
          (x: ''masterIdentityMap[${escapeShellArg (removeSuffix "\n" x.pubkey)}]=${escapeShellArg x.identity}'')
          (filter (x: x.pubkey != null) mergedMasterIdentities))
      }

      # For master identies with no explicit pubkey, try extracting a pubkey from the file first.
      # Collect final identity arguments for encryption in an array.
      masterIdentityArgs=()
      # shellcheck disable=SC2041,SC2043
      for file in ${
        concatStringsSep " "
        (map
          (x: "${escapeShellArg x.identity}")
          (filter (x: x.pubkey == null) mergedMasterIdentities))
      }; do
        # Keep track if a file was processed.
        file_processed=false

        # Only consider files that contain exactly one identity, since files with multiple identities are allowed,
        # but are ambiguous with respect to the pairings between identities and pubkeys.
        if [[ $(grep -c "^AGE-" "$file") == 1 ]]; then
          if grep -q "^AGE-PLUGIN-YUBIKEY-" "$file"; then
            # If the file specifies "Recipient: age1yubikey1<pubkey>", extract recipient and specify with "-r".
            if mapfile -t pubkeys < <(grep 'Recipient: age1yubikey1' "$file" | grep -Eoh 'age1yubikey1[0-9a-z]+'); then
              if [[ ''${#pubkeys[@]} -eq 0 ]]; then
                error "Failed to find public key for master identity: $file"
                error "If this is a keygrab, a comment should have been added by age-plugin-yubikey that seems to be missing here"
                error "Please re-export the identity from age-plugin-yubikey or manually add the \"# Recipient: age1yubikey1<your_pubkey>\""
                error "string in front of the key."
                error "Alternatively, you can also specify the correct public key in \`config.age.rekey.masterIdentities\`."
                exit 1
              elif [[ ''${#pubkeys[@]} -eq 1 ]]; then
                masterIdentityMap["''${pubkeys[0]}"]="$file"
                masterIdentityArgs+=("-r" "''${pubkeys[0]}")
                file_processed=true
              else
                error "Found more than one public key in master identity: $file"
                error "agenix-rekey only supports a one-to-one correspondence between identities and their pubkeys."
                error "If this is not intended, please avoid the \"# Recipient: \" comment in front of the incorrect key."
                error "Alternatively, specify the correct public key in \`config.age.rekey.masterIdentities\`."
                error "List of public keys found in the file:"
                for pubkey in "''${pubkeys[@]}"; do
                  error "  $pubkey"
                done
                exit 1
              fi
            fi
          fi
        fi

        # If the identity was not processed at this point, pass it to (r)age as a regular identity file,
        # so that the program can decide what to do with it.
        if [[ "$file_processed" == false ]]; then
          masterIdentityArgs+=("-i" "$file")
        fi
      done

      primaryIdentityArgs=()
      if [[ -n "''${AGENIX_REKEY_PRIMARY_IDENTITY:-}" ]]; then
        pubkey_found=false
        for pubkey in "''${!masterIdentityMap[@]}"; do
          if [[ "$pubkey" == "$AGENIX_REKEY_PRIMARY_IDENTITY" ]]; then
            primaryIdentityArgs=("-i" "''${masterIdentityMap["$pubkey"]}")
            pubkey_found=true
            break
          fi
        done
        if [[ "$pubkey_found" == false ]]; then
          warn "Environment variable AGENIX_REKEY_PRIMARY_IDENTITY is set, but matches none of the pubkeys found by agenix-rekey."
          warn "Please verify that your pubkeys and identities are set up correctly."
          warn "Value of AGENIX_REKEY_PRIMARY_IDENTITY: \"$AGENIX_REKEY_PRIMARY_IDENTITY\""
          warn "Pubkeys found:"
          for pubkey in "''${!masterIdentityMap[@]}"; do
            warn "  $pubkey for file \"''${masterIdentityMap["$pubkey"]}\""
          done
        fi
      fi

      # Use first argument to determine encryption mode.
      # Pass all other arguments to (r)age.
      if [[ "$1" == "encrypt" ]]; then
        ${envPath} ${ageProgram} -e "''${masterIdentityArgs[@]}" ${extraEncryptionPubkeyArgs} "''${@:2}"
      else
        # Prepend primary key argument before all others to it gets the first attempt at decrypting.
        if [[ -n "''${AGENIX_REKEY_PRIMARY_IDENTITY:-}" ]] && [[ "''${AGENIX_REKEY_PRIMARY_IDENTITY_ONLY:-}" == true ]]; then
          ${envPath} ${ageProgram} -d "''${primaryIdentityArgs[@]}" "''${@:2}"
        else
          ${envPath} ${ageProgram} -d "''${primaryIdentityArgs[@]}" ${decryptionMasterIdentityArgs} "''${@:2}"
        fi
      fi
    '';
  };
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
  ageMasterEncrypt = "${ageWrapperScript}/bin/ageWrapper encrypt";
  ageMasterDecrypt = "${ageWrapperScript}/bin/ageWrapper decrypt";
  ageHostEncrypt = hostAttrs: let
    hostPubkey = removeSuffix "\n" hostAttrs.config.age.rekey.hostPubkey;
  in "${envPath} ${ageProgram} -e ${pubkeyOpt hostPubkey}";
}
