{ pkgs, ... }@inputs:
let
  inherit (pkgs.lib)
    concatStringsSep
    escapeShellArg
    optionalString
    ;

  inherit (import ../nix/lib.nix inputs)
    ageMasterDecrypt
    validRelativeSecretPaths
    ;

in
pkgs.writeShellScriptBin "agenix-view" ''
  set -uo pipefail

  function die() { echo "[1;31merror:[m $*" >&2; exit 1; }
  function show_help() {
    echo 'Usage: agenix view [OPTIONS] [FILE]'
    echo 'Print age secret files tyo stdout with your master identity'
    echo ""
    echo 'OPTIONS:'
    echo '-h, --help                Show help'
    echo ""
    echo 'FILE    An age-encrypted file to view.'
    echo '          If not given, a fzf selector of used secrets will be shown.'
  }

  if [[ ! -e flake.nix ]] ; then
    die "Please execute this script from your flake's root directory."
  fi

  POSITIONAL_ARGS=()
  force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      "help"|"--help"|"-help"|"-h")
        show_help
        exit 1
        ;;
      "--")
        shift
        POSITIONAL_ARGS+=("$@")
        break
        ;;
      "-"*|"--"*) die "Invalid option '$1'" ;;
      *) POSITIONAL_ARGS+=("$1") ;;
    esac
    shift
  done

  # If file is not given, show fzf
  case "''${#POSITIONAL_ARGS[@]}" in
    0)
      ${optionalString (builtins.length validRelativeSecretPaths == 0) ''
        die "No relevant secret definitions were found for any host."
        break
      ''}
      FILE=$(echo ${escapeShellArg (concatStringsSep "\n" validRelativeSecretPaths)} \
        | ${pkgs.fzf}/bin/fzf --preview "bash -c 'agenix view {1} 2> /dev/null'" --tiebreak=end --bind=tab:down,btab:up,change:top --height='~50%' --tac --cycle --layout=reverse) \
        || die "No file selected. Aborting."
    ;;
    1) FILE="''${POSITIONAL_ARGS[0]}" ;;
    *)
      show_help
      exit 1
      ;;
  esac
  [[ "$FILE" != *".age" ]] && echo "[1;33mwarning:[m secrets should use the .age suffix by convention"

  # Extract suffix before .age, if there is any.
  SUFFIX=$(basename "$FILE")
  SUFFIX=''${SUFFIX%.age}
  if [[ "''${SUFFIX}" == *.* ]]; then
    # Extract the second suffix if there is one
    SUFFIX=''${SUFFIX##*.}
  else
    # Use txt otherwise
    SUFFIX="txt"
  fi

  CLEARTEXT_FILE=$(${pkgs.coreutils}/bin/mktemp --suffix=".$SUFFIX")
  ENCRYPTED_FILE=$(${pkgs.coreutils}/bin/mktemp --suffix=".$SUFFIX")

  function cleanup() {
    [[ -e "$CLEARTEXT_FILE" ]] && rm "$CLEARTEXT_FILE"
    [[ -e "$ENCRYPTED_FILE" ]] && rm "$ENCRYPTED_FILE"
  }; trap "cleanup" EXIT

  if [[ -e "$FILE" ]]; then
    ${ageMasterDecrypt} -o "$CLEARTEXT_FILE" "$FILE" \
      || die "Failed to decrypt file. Aborting."
  else
    mkdir -p "$(dirname "$FILE")" \
      || die "Could not create parent directory"
  fi

  cat "''${EDITOR_OPTS[@]}" "$CLEARTEXT_FILE" \
    || die "Cat returned unsuccessful exit status. Aborting."

  exit 0
''
