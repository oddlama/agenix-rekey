{ pkgs, ... }@inputs:
let
  inherit (pkgs.lib)
    concatStringsSep
    escapeShellArg
    optionalString
    ;

  inherit (import ../nix/lib.nix inputs)
    ageMasterEncrypt
    ageMasterDecrypt
    validRelativeSecretPaths
    ;

in
pkgs.writeShellScriptBin "agenix-edit-view" ''
  set -uo pipefail

  function die() { echo "[1;31merror:[m $*" >&2; exit 1; }
  function show_help() {
    app="$1"
    echo "Usage: agenix $app [OPTIONS] [FILE]"
    if [[ $app == "edit" ]]; then
      echo 'Create/edit/view age secret files with $EDITOR, fzf and your master identity'
    else
      echo 'View age secret files with fzf and your master identity'
    fi
    echo ""
    echo 'OPTIONS:'
    echo '-h, --help                Show help'
    if [[ $app == "edit" ]]; then
      echo '-i, --input INFILE        Instead of editing FILE with $EDITOR, directly use the'
      echo '                            content of INFILE and encrypt it to FILE.'
      echo '-f, --force               Always write out the file, regardless if the contents are unchanged.'
      echo '                            Can be useful if you'"'"'re adding masterIdentities.'
      echo '-p, --preview             Preview the selected secret in fzf.'
      echo '                            Can be insecure, as the secrets are shown in plain-text.'
    fi
    echo ""
    if [[ $app == "edit" ]]; then
      echo "FILE    An age-encrypted file to edit or a new file to create."
    else
      echo "FILE    An age-encrypted file to view."
    fi
    echo '          If not given, a fzf selector of used secrets will be shown.'
  }

  if [[ ! -e flake.nix ]] ; then
    die "Please execute this script from your flake's root directory."
  fi

  POSITIONAL_ARGS=()
  force=0
  preview=0
  app=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      "view")
        app="view"
        ;;
      "edit")
        app="edit"
        ;;
      "help"|"--help"|"-help"|"-h")
        show_help "$app"
        exit 1
        ;;
      "--input"|"-i")
        INFILE="$2"
        [[ -f "$INFILE" ]] || die "Input file not found: '$INFILE'"
        shift
        ;;
      "--force"|"-f")
        force=1
        ;;
      "--preview"|"-p")
        preview=1
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
        die "No relevant secret definitions were found for any host. Pass a filename to create a new secret regardless of whether it is already used."
        break
      ''}
      if [[ "$preview" == 1 ]]; then
        FILE=$(echo ${escapeShellArg (concatStringsSep "\n" validRelativeSecretPaths)} \
          | ${pkgs.fzf}/bin/fzf --preview "bash -c 'agenix view {1} 2> /dev/null'" --tiebreak=end --bind=tab:down,btab:up,change:top --height='~50%' --tac --cycle --layout=reverse) \
          || die "No file selected. Aborting."
      else
        FILE=$(echo ${escapeShellArg (concatStringsSep "\n" validRelativeSecretPaths)} \
          | ${pkgs.fzf}/bin/fzf --tiebreak=end --bind=tab:down,btab:up,change:top --height='~50%' --tac --cycle --layout=reverse) \
          || die "No file selected. Aborting."
      fi
    ;;
    1) FILE="''${POSITIONAL_ARGS[0]}" ;;
    *)
      show_help "$app"
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
    [[ -z ''${INFILE+x} ]] || die "Refusing to overwrite existing file when using --input"

    ${ageMasterDecrypt} -o "$CLEARTEXT_FILE" "$FILE" \
      || die "Failed to decrypt file. Aborting."
  else
    mkdir -p "$(dirname "$FILE")" \
      || die "Could not create parent directory"
  fi

  if [[ $app == "edit" ]]; then
    shasum_before="$(${pkgs.coreutils}/bin/sha512sum "$CLEARTEXT_FILE")"

    if [[ -n ''${INFILE+x} ]] ; then
      ${pkgs.coreutils}/bin/cp "$INFILE" "$CLEARTEXT_FILE"
    else
      # Editor options to prevent leaking information
      EDITOR_OPTS=()
      case "$EDITOR" in
        *nvim*)
          EDITOR_OPTS=("--cmd" 'au BufRead * setlocal nobackup nomodeline noshelltemp noswapfile noundofile nowritebackup shadafile=NONE') ;;
        *vim*)
          EDITOR_OPTS=("--cmd" 'au BufRead * setlocal nobackup nomodeline noshelltemp noswapfile noundofile nowritebackup viminfo=""') ;;
        *) ;;
      esac
      $EDITOR "''${EDITOR_OPTS[@]}" "$CLEARTEXT_FILE" \
        || die "Editor returned unsuccessful exit status. Aborting, original is left unchanged."
    fi

    shasum_after="$(${pkgs.coreutils}/bin/sha512sum "$CLEARTEXT_FILE")"
    if [[ "$force" == 0 && "$shasum_before" == "$shasum_after" ]]; then
      echo "No content changes, original is left unchanged."
      exit 0
    fi

    ${ageMasterEncrypt} -o "$ENCRYPTED_FILE" "$CLEARTEXT_FILE" \
      || die "Failed to (re)encrypt edited file, original is left unchanged."
    ${pkgs.coreutils}/bin/cp --no-preserve=all "$ENCRYPTED_FILE" "$FILE" # cp instead of mv preserves original attributes and permissions
  else
    ${pkgs.coreutils}/bin/cat "$CLEARTEXT_FILE" \
      || die "Cat returned unsuccessful exit status. Aborting."
  fi

  exit 0
''
