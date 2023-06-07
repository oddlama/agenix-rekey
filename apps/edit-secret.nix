{
  self,
  lib,
  pkgs,
  nixosConfigurations,
  ...
}: let
  inherit
    (lib)
    concatLists
    concatMapStrings
    concatStringsSep
    escapeShellArg
    filter
    hasPrefix
    mapAttrsToList
    removePrefix
    substring
    unique
    warn
    ;

  flakeDir = toString self.outPath;
  relativeToFlake = filePath: let
    fileStr = toString filePath;
  in
    if hasPrefix flakeDir fileStr
    then "." + removePrefix flakeDir fileStr
    else warn "Ignoring ${fileStr} which isn't a direct subpath of the flake directory ${flakeDir}, meaning this script cannot determine it's true origin!" null;

  mergeArray = f: unique (concatLists (mapAttrsToList (_: f) nixosConfigurations));
  mergedAgePlugins = mergeArray (x: x.config.age.rekey.agePlugins or []);
  mergedMasterIdentities = mergeArray (x: x.config.age.rekey.masterIdentities or []);
  mergedExtraEncryptionPubkeys = mergeArray (x: x.config.age.rekey.extraEncryptionPubkeys or []);
  mergedSecrets = mergeArray (x: filter (x: x != null) (mapAttrsToList (_: s: s.rekeyFile) x.config.age.secrets));
  # Relative path to all rekeyable secrets. Filters and warns on paths that are not part of the root flake.
  validRelativeSecretPaths = builtins.sort (a: b: a < b) (filter (x: x != null) (map relativeToFlake mergedSecrets));

  isAbsolutePath = x: substring 0 1 x == "/";
  envPath = ''PATH="$PATH${concatMapStrings (x: ":${x}/bin") mergedAgePlugins}"'';
  masterIdentityArgs = concatMapStrings (x: ''-i ${escapeShellArg x} '') mergedMasterIdentities;
  extraEncryptionPubkeys =
    concatMapStrings (
      x:
        if isAbsolutePath x
        then ''-R ${escapeShellArg x} ''
        else ''-r ${escapeShellArg x} ''
    )
    mergedExtraEncryptionPubkeys;
in
  pkgs.writeShellScript "edit-secret" ''
    set -uo pipefail

    function die() { echo "[1;31merror:[m $*" >&2; exit 1; }
    function show_help() {
      echo 'app edit-secret - create/edit age secret files with $EDITOR'
      echo ""
      echo "nix run .#edit-secret [FILE]"
      echo ""
      echo 'options:'
      echo '-h, --help                Show help'
      echo '-i, --input INFILE        Instead of editing FILE with $EDITOR, directly use the'
      echo '                            content of INFILE and encrypt it to FILE.'
      echo ""
      echo 'FILE    An age-encrypted file to edit or a new file to create.'
      echo '          If not given, a fzf selector of used secrets will be shown.'
      echo ""
      echo 'age plugins: ${concatStringsSep ", " mergedAgePlugins}'
      echo 'master identities: ${concatStringsSep ", " mergedMasterIdentities}'
      echo 'extra encryption pubkeys: ${concatStringsSep ", " mergedExtraEncryptionPubkeys}'
    }

    if [[ ! -e flake.nix ]] ; then
      echo "Please execute this script from your flake's root directory." >&2
      exit 1
    fi

    POSITIONAL_ARGS=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        "help"|"--help"|"-help"|"-h")
          show_help
          exit 1
          ;;
        "--input"|"-i")
          INFILE="$2"
          [[ -f "$INFILE" ]] || die "Input file not found: '$INFILE'"
          shift
          ;;
        "--") break ;;
        "-"*|"--"*) die "Invalid option '$1'" ;;
        *) POSITIONAL_ARGS+=("$1") ;;
      esac
      shift
    done

    # If file is not given, show fzf
    case "''${#POSITIONAL_ARGS[@]}" in
      0)
        FILE=$(echo ${escapeShellArg (concatStringsSep "\n" validRelativeSecretPaths)} \
          | ${pkgs.fzf}/bin/fzf --tiebreak=end --bind=tab:down,btab:up,change:top --height='~50%' --tac --cycle --layout=reverse) \
          || die "No file selected. Aborting."
      ;;
      1) FILE="''${POSITIONAL_ARGS[0]}" ;;
      *)
        show_help
        exit 1
        ;;
    esac
    [[ "$FILE" != *".age" ]] && echo "[1;33mwarning:[m secrets should use the .age suffix by convention"

    CLEARTEXT_FILE=$(${pkgs.mktemp}/bin/mktemp)
    ENCRYPTED_FILE=$(${pkgs.mktemp}/bin/mktemp)

    function cleanup() {
      [[ -e "$CLEARTEXT_FILE" ]] && rm "$CLEARTEXT_FILE"
      [[ -e "$ENCRYPTED_FILE" ]] && rm "$ENCRYPTED_FILE"
    }; trap "cleanup" EXIT

    if [[ -e "$FILE" ]]; then
      [[ -z ''${INFILE+x} ]] || die "Refusing to overwrite existing file when using --input"

      ${envPath} ${pkgs.rage}/bin/rage -d ${masterIdentityArgs} -o "$CLEARTEXT_FILE" "$FILE" \
        || die "Failed to decrypt file. Aborting."
    else
      mkdir -p "$(dirname "$FILE")" \
        || die "Could not create parent directory"
    fi
    shasum_before="$(sha512sum "$CLEARTEXT_FILE")"

    if [[ -n ''${INFILE+x} ]] ; then
      cp "$INFILE" "$CLEARTEXT_FILE"
    else
      # Editor options to prevent leaking information
      EDITOR_OPTS=()
      case "$EDITOR" in
        vim|"vim "*|nvim|"nvim "*)
          EDITOR_OPTS=("--cmd" 'au BufRead * setlocal history=0 nobackup nomodeline noshelltemp noswapfile noundofile nowritebackup secure viminfo=""') ;;
        *) ;;
      esac
      $EDITOR "''${EDITOR_OPTS[@]}" "$CLEARTEXT_FILE" \
        || die "Editor returned unsuccessful exit status. Aborting, original is left unchanged."
    fi

    shasum_after="$(sha512sum "$CLEARTEXT_FILE")"
    if [[ "$shasum_before" == "$shasum_after" ]]; then
      echo "No content changes, original is left unchanged."
      exit 0
    fi

    ${envPath} ${pkgs.rage}/bin/rage -e ${masterIdentityArgs} ${extraEncryptionPubkeys} -o "$ENCRYPTED_FILE" "$CLEARTEXT_FILE" \
      || die "Failed to (re)encrypt edited file, original is left unchanged."
    cp --no-preserve=all "$ENCRYPTED_FILE" "$FILE" # cp instead of mv preserves original attributes and permissions

    exit 0
  ''
