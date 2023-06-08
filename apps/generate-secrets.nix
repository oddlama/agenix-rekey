{
  self,
  lib,
  pkgs,
  nixosConfigurations,
  ...
} @ inputs: let
  inherit
    (lib)
    assertMsg
    attrNames
    attrValues
    concatStringsSep
    escapeShellArg
    foldl'
    hasAttr
    hasPrefix
    removePrefix
    ;

  inherit
    (import ../nix/lib.nix inputs)
    userFlakeDir
    rageMasterEncrypt
    ;

  relativeToFlake = filePath: let
    fileStr = toString filePath;
  in
    assert assertMsg (hasPrefix userFlakeDir fileStr) "Cannot generate ${fileStr} as it isn't a direct subpath of the flake directory ${userFlakeDir}, meaning this script cannot determine its true origin!";
      "." + removePrefix userFlakeDir fileStr;

  # Add the given secret to the set, indexed by its relative path.
  # If the path already exists, this makes sure that the definition is the same.
  addGeneratedSecretChecked = host: set: secretName: let
    secret = nixosConfigurations.${host}.config.age.secrets.${secretName};
    sourceFile = relativeToFlake secret.rekeyFile;
    script = secret._generationScript {
      file = sourceFile;
      name = secretName;
      inherit secret pkgs lib;
    };
  in
    # Filter secrets that don't need to be generated
    if secret._generationScript == null
    then set
    else
      # Assert that the generator is the same if it was defined on multiple hosts
      assert assertMsg (hasAttr sourceFile set -> script == set.${sourceFile}.script)
      "Generator definition of ${secretName} on ${host} differs from definitions on other hosts: ${concatStringsSep "," set.${sourceFile}.defs}";
        set
        // {
          ${sourceFile} = {
            inherit secret sourceFile secretName script;
            defs = (set.${sourceFile}.defs or []) ++ ["${host}:${secretName}"];
          };
        };

  # Collects all secrets that have generators across all hosts.
  # Deduplicates secrets if the generator is the same, otherwise throws an error.
  secretsWithGenerators =
    foldl'
    (set: host:
      foldl'
      (addGeneratedSecretChecked host)
      set
      (attrNames nixosConfigurations.${host}.config.age.secrets))
    {} (attrNames nixosConfigurations);

  # The command that actually generates a secret.
  secretGenerationCommand = secret: ''
    if wants_secret ${escapeShellArg secret.sourceFile} ; then
      if [[ ! -e ${escapeShellArg secret.sourceFile} ]] || [[ "$FORCE_GENERATE" == true ]]; then
        echo "Generating secret [34m"${escapeShellArg secret.sourceFile}"[m [90m("${concatStringsSep ", " (map escapeShellArg secret.defs)}")[m"
        (
          ${secret.script}
        ) \
          | ${rageMasterEncrypt} -o ${escapeShellArg secret.sourceFile} \
          || die "Failed to (re)encrypt edited file, original is left unchanged."
      else
        echo "[90mSkipping existing secret "${escapeShellArg secret.sourceFile} ("${concatStringsSep ", " (map escapeShellArg secret.defs)}")"[m"
      fi
    fi
  '';
in
  pkgs.writeShellScript "generate-secrets" ''
    set -euo pipefail

    function die() { echo "[1;31merror:[m $*" >&2; exit 1; }
    function show_help() {
      echo 'app generate-secrets - Creates secrets using their generators'
      echo ""
      echo "nix run .#generate-secrets [OPTIONS] [SECRET]..."
      echo ""
      echo 'OPTIONS:'
      echo '-h, --help                Show help'
      echo '-f, --force-generate      Force generating existing secrets'
    }

    FORCE_GENERATE=false
    POSITIONAL_ARGS=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        "help"|"--help"|"-help"|"-h")
          show_help
          exit 1
          ;;
        "--force-generate"|"-f")
          FORCE_GENERATE=true
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

    # $1: secret file to test if wanted
    function wants_secret() {
      if [[ ''${#POSITIONAL_ARGS[@]} -eq 0 ]]; then
        return 0
      else
        for secret in ''${POSITIONAL_ARGS[@]} ; do
          [[ "$(realpath -m "$1")" == "$(realpath -m "$secret")" ]] && return 0
        done
        return 1
      fi
    }

    if [[ ! -e flake.nix ]] ; then
      die "Please execute this script from your flake's root directory."
    fi

    KNOWN_SECRETS=(
      ${concatStringsSep "\n" (map (x: escapeShellArg x.sourceFile) (attrValues secretsWithGenerators))}
    )
    for secret in ''${POSITIONAL_ARGS[@]} ; do
      for known in ''${KNOWN_SECRETS[@]} ; do
        [[ "$(realpath -m "$secret")" == "$(realpath -m "$known")" ]] && continue 2
      done
      die "Provided path matches no known secret: $secret"
    done

    ${concatStringsSep "\n" (map secretGenerationCommand (attrValues secretsWithGenerators))}
  ''
