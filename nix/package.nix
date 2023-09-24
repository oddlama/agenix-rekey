{
  lib,
  writeShellScriptBin,
}: let
  allApps = ["edit-secret" "generate-secrets" "rekey"];
  caseForApp = app: ''
    # Command ${app}
    ${lib.escapeShellArg app})
      echo "Indexing secrets..."
      SCRIPT=$(nix-build ${../apps/wrapper.nix} \
        --argstr userFlakePath "$(realpath -e .)" \
        --arg app ${../apps/${app}.nix})
        exec "$SCRIPT" "$@"
      ;;
    '';
in writeShellScriptBin "agenix" ''
  set -euo pipefail

  function die() { echo "[1;31merror:[m $*" >&2; exit 1; }
  function show_help() {
    echo 'Usage: agenix [COMMAND]'
    echo "Edit, generate or rekey secrets for agenix."
    echo "Add help or --help to a subcommand to view a command specific help."
    echo ""
    echo 'COMMANDS:'
    echo '  rekey                   Re-encrypts secrets for hosts that require them.'
    echo '  edit                    Create/edit age secret files with $EDITOR and your master identity'
    echo '  generate                Automatically generates secrets that have generators'
  }

  USER_FLAKE_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd) \
    || die "Could not determine current working directory. Something went very wrong."
  [[ -e "$USER_FLAKE_DIR/flake.nix" ]] \
    || die "Could not determine location of your project's flake.nix. Please run this at or below your main directory containing the flake.nix."
  cd "$USER_FLAKE_DIR"

  [[ $# -gt 0 ]] || {
    show_help
    exit 1
  }

  COMMAND=$1
  shift

  case "$COMMAND" in
    "help"|"--help"|"-help"|"-h")
      show_help
      exit 1
      ;;

    ${lib.concatMapStrings caseForApp allApps}

    *) die "Unknown command: $COMMAND" ;;
  esac
''
