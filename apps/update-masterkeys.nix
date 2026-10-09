{ pkgs, ... }@inputs:
let
  inherit (import ../nix/lib.nix inputs)
    ageMasterEncrypt
    ageMasterDecrypt
    masterIdentitySessionWrapper
    validRelativeSecretPaths
    ;

  masterIdentitySessionPrelude =
    if masterIdentitySessionWrapper == null then
      ""
    else
      ''
        if [[ "''${AGENIX_REKEY_MASTER_IDENTITY_SESSION_ACTIVE:-}" != true ]]; then
          export AGENIX_REKEY_MASTER_IDENTITY_SESSION_ACTIVE=true
          export AGENIX_REKEY_INTERNAL_OPERATION_PLAN_SHOWN=true
          exec ${pkgs.lib.getExe masterIdentitySessionWrapper} -- "$0" "''${ORIGINAL_ARGS[@]}"
        fi
      '';
in
pkgs.writeShellScriptBin "agenix-update-masterkeys" ''
  set -uo pipefail

  ORIGINAL_ARGS=("$@")

  function die() { echo "[1;31merror:[m $*" >&2; exit 1; }
  function show_help() {
    echo 'Usage: agenix update-masterkeys [OPTIONS]'
    echo 'Update all stored secrets with a new set of masterkeys.'
    echo
    echo 'OPTIONS:'
    echo '-h, --help    Show help'
  }

  while [[ $# -gt 0 ]]; do
    case "$1" in
      "help"|"--help"|"-help"|"-h")
        show_help
        exit 0
        ;;
      *) die "Invalid option '$1'" ;;
    esac
  done

  if [[ ! -e flake.nix ]] ; then
    die "Please execute this script from your flake's root directory."
  fi

  if [[ "''${AGENIX_REKEY_MASTER_IDENTITY_SESSION_ACTIVE:-}" != true || "''${AGENIX_REKEY_INTERNAL_OPERATION_PLAN_SHOWN:-}" != true ]]; then
    echo 'Planned operations:'
    ${
      if masterIdentitySessionWrapper == null then
        ""
      else
        "echo '  Use one command-scoped master identity session.'"
    }
    echo '  Update master-key recipients for these files:'
    ${
      if validRelativeSecretPaths == [ ] then
        "echo '    (none)'"
      else
        builtins.concatStringsSep "\n" (
          builtins.map (path: "printf '    %s\\n' ${pkgs.lib.escapeShellArg path}") validRelativeSecretPaths
        )
    }
    echo '  Each file will be decrypted, re-encrypted for the configured master recipients,'
    echo '  and replaced only after re-encryption succeeds.'
    echo 'End of plan.'
    echo
  fi

  ${masterIdentitySessionPrelude}

  ${builtins.concatStringsSep "" (
    builtins.map (
      path: # bash
      ''
        CLEARTEXT_FILE=$(${pkgs.coreutils}/bin/mktemp)
        ENCRYPTED_FILE=$(${pkgs.coreutils}/bin/mktemp)

        function cleanup() {
          [[ -e "$CLEARTEXT_FILE" ]] && rm "$CLEARTEXT_FILE"
          [[ -e "$ENCRYPTED_FILE" ]] && rm "$ENCRYPTED_FILE"
        }; trap "cleanup" EXIT

        shasum_before="$(${pkgs.coreutils}/bin/sha512sum "${path}")"

        ${ageMasterDecrypt} -o "$CLEARTEXT_FILE" "${path}" \
            || die "Failed to decrypt file. Aborting."
        ${ageMasterEncrypt} -o "$ENCRYPTED_FILE" "$CLEARTEXT_FILE" \
            || die "Failed to re-encrypt file. Aborting."

        shasum_after="$(${pkgs.coreutils}/bin/sha512sum "$ENCRYPTED_FILE")"
        if [[ "$shasum_before" == "$shasum_after" ]]; then
          echo "[1;90m    Skipping[m [90m[already rekeyed] "${path}"[m"
        else
          ${pkgs.coreutils}/bin/cp --no-preserve=all "$ENCRYPTED_FILE" "${path}" # cp instead of mv preserves original attributes and permissions
          echo "[1;32m    Updated masterkeys of[m [34m"${path}"[m"
        fi

        rm "$CLEARTEXT_FILE"
        rm "$ENCRYPTED_FILE"
      '') validRelativeSecretPaths
  )}
  exit 0
''
