{
  pkgs,
  nodes,
  writeDephash ? false,
  ...
}@inputs:
let
  inherit (pkgs.lib)
    any
    assertMsg
    attrNames
    attrValues
    concatStringsSep
    escapeShellArg
    filter
    filterAttrs
    flip
    foldl'
    hasAttr
    hasPrefix
    head
    length
    mapAttrs
    mapAttrsToList
    removePrefix
    stringsWithDeps
    warnIf
    ;

  inherit (import ../nix/lib.nix inputs)
    userFlakeDir
    ageMasterDecrypt
    ageMasterEncrypt
    ;

  relativeToFlake =
    filePath:
    let
      fileStr = builtins.unsafeDiscardStringContext (toString filePath);
    in
    assert assertMsg (hasPrefix userFlakeDir fileStr)
      "Cannot generate ${fileStr} as it isn't a direct subpath of the flake directory ${userFlakeDir}, meaning this script cannot determine its true origin!";
    "." + removePrefix userFlakeDir fileStr;

  mapListOrAttrs = f: x: if builtins.isList x then map f x else mapAttrs (_: f) x;
  mapListOrAttrValues = f: x: if builtins.isList x then map f x else mapAttrsToList (_: f) x;
  filterListOrAttrValues = f: x: if builtins.isList x then filter f x else filterAttrs (_: f) x;

  # Finds the host where the given secret is defines. Matches
  # based on secret.id and secret.rekeyFile. If multiple matches
  # exist, a warning is issued and the first is returned.
  findHost =
    secret:
    let
      matchingHosts = filter (
        host:
        any (s: s.id == secret.id && s.rekeyFile == secret.rekeyFile) (
          attrValues nodes.${host}.config.age.secrets
        )
      ) (attrNames nodes);
    in
    warnIf (length matchingHosts > 1)
      "Multiple hosts provide a secret with rekeyFile=[33m${toString secret.rekeyFile}[m, which may have undesired side effects when used in secret generator dependencies."
      (head matchingHosts);

  # Add the given secret to the set, indexed by its relative path.
  # If the path already exists, this makes sure that the definition is the same.
  addGeneratedSecretChecked =
    host: set: secretName:
    let
      secret = nodes.${host}.config.age.secrets.${secretName};
      sourceFile =
        assert assertMsg (
          secret.rekeyFile != null
        ) "Host ${host}: age.secrets.${secretName}: `rekeyFile` must be set when using a generator.";
        relativeToFlake secret.rekeyFile;
      script = secret.generator._script {
        inherit secret pkgs;
        inherit (pkgs) lib;
        file = sourceFile;
        name = secretName;
        decrypt = ageMasterDecrypt;
        deps = flip mapListOrAttrs secret.generator.dependencies (dep: {
          host = findHost dep;
          name = dep.id;
          file = relativeToFlake dep.rekeyFile;
        });
      };
    in
    # Filter secrets that don't need to be generated
    if secret.generator == null then
      set
    else
      # Assert that the generator is the same if it was defined on multiple hosts
      assert assertMsg (hasAttr sourceFile set -> script == set.${sourceFile}.script)
        "Generator definition of ${secretName} on ${host} differs from definitions on other hosts: ${
          concatStringsSep "," set.${sourceFile}.defs
        }";
      set
      // {
        ${sourceFile} = {
          inherit
            secret
            sourceFile
            secretName
            script
            ;
          defs = (set.${sourceFile}.defs or [ ]) ++ [ "${host}:${secretName}" ];
        };
      };

  # Collects all secrets that have generators across all hosts.
  # Deduplicates secrets if the generator is the same, otherwise throws an error.
  secretsWithContext = foldl' (
    set: host: foldl' (addGeneratedSecretChecked host) set (attrNames nodes.${host}.config.age.secrets)
  ) { } (attrNames nodes);

  # The command that actually generates a secret.
  secretGenerationCommand = contextSecret: ''
    if wants_secret ${escapeShellArg contextSecret.sourceFile} ${escapeShellArg (concatStringsSep "," contextSecret.secret.generator.tags)} ; then
      dep_hash_file=${escapeShellArg contextSecret.sourceFile}.dephash
      deps_changed=false
      ${if contextSecret.secret.generator.dependencies == [ ] || contextSecret.secret.generator.dependencies == { } then ''
      dep_hash=""
      '' else ''
      dep_hash=$(${pkgs.coreutils}/bin/sha256sum ${
        concatStringsSep " " (
          flip mapListOrAttrValues contextSecret.secret.generator.dependencies (
            dep: escapeShellArg (relativeToFlake dep.rekeyFile)
          )
        )
      } 2>/dev/null | ${pkgs.coreutils}/bin/sort | ${pkgs.coreutils}/bin/sha256sum | cut -d' ' -f1)

      if [[ -f "$dep_hash_file" ]]; then
        # Content hash exists — use it for dependency change detection
        old_dep_hash=$(cat "$dep_hash_file" 2>/dev/null)
        [[ "$dep_hash" != "$old_dep_hash" ]] && deps_changed=true
      else
        # No content hash — fall back to mtime comparison
        dep_mtimes=(
          ${concatStringsSep "\n" (
            flip mapListOrAttrValues contextSecret.secret.generator.dependencies (
              dep: "\"$(stat -c %Y ${escapeShellArg (relativeToFlake dep.rekeyFile)} 2>/dev/null || echo 1)\""
            )
          )}
        )
        mtime_newest_dep=$(IFS=$'\n'; sort -nr <<< "''${dep_mtimes[*]}" | head -n1)
        mtime_this=$(stat -c %Y ${escapeShellArg contextSecret.sourceFile} 2>/dev/null || echo 0)
        [[ "$mtime_newest_dep" -gt "$mtime_this" ]] && deps_changed=true
      fi
      ''}

      # Regenerate if the file doesn't exist, dependencies changed, or we should force regeneration
      if [[ ! -e ${escapeShellArg contextSecret.sourceFile} ]] || [[ "$deps_changed" == true ]] || [[ "$FORCE_GENERATE" == true ]]; then
        echo "[1;32m  Generating[m [34m"${escapeShellArg contextSecret.sourceFile}"[m [90m("${concatStringsSep "', '" (map escapeShellArg contextSecret.defs)}")[m"
        mkdir -p "$(dirname ${escapeShellArg contextSecret.sourceFile})"

        {
          ( ${contextSecret.script} ) || {
            rc="$?"
            exec 1>&-
            die "Generator exited with status $rc."
          }
        } | ${ageMasterEncrypt} -o ${escapeShellArg contextSecret.sourceFile} \
          || die "Failed to generate or encrypt secret."

        if [[ "$WRITE_DEPHASH" == true ]] && [[ -n "$dep_hash" ]]; then
          echo "$dep_hash" > "$dep_hash_file"
        fi

        if [[ "$ADD_TO_GIT" == true ]]; then
          git add ${escapeShellArg contextSecret.sourceFile} \
            || die "Failed to add generated secret to git"
          if [[ "$WRITE_DEPHASH" == true ]] && [[ -n "$dep_hash" ]]; then
            git add "$dep_hash_file" \
              || die "Failed to add dependency hash to git"
          fi
        fi
      else
        echo "[1;90m    Skipping[m [90m[already exists] "${escapeShellArg contextSecret.sourceFile}" ("${concatStringsSep "', '" (map escapeShellArg contextSecret.defs)}")[m"
      fi
    fi
  '';

  # Use stringsWithDeps to compute an ordered list of secret generation commands.
  # Any dependencies of generators are guaranteed to come first, such that
  # generators may use the result of other secrets.
  orderedGenerationCommands =
    let
      stages = flip mapAttrs secretsWithContext (
        _: contextSecret:
        stringsWithDeps.fullDepEntry (secretGenerationCommand contextSecret) (
          mapListOrAttrValues (x: relativeToFlake x.rekeyFile) (
            filterListOrAttrValues (dep: dep.generator != null) contextSecret.secret.generator.dependencies
          )
        )
      );
    in
    stringsWithDeps.textClosureMap (x: x) stages (attrNames stages);

  # It only makes sense to clean up directories of generated secrets
  # for the nodes that have a dedicated generatedSecretsDir set.
  nodesWithGeneratedSecretsDir = filter (x: x.config.age.rekey.generatedSecretsDir != null) (
    attrValues nodes
  );
in
pkgs.writeShellScriptBin "agenix-generate" ''
  set -euo pipefail

  function die() { echo "[1;31merror:[m $*" >&2; exit 1; }
  function show_help() {
    echo 'Usage: agenix generate [OPTIONS] [SECRET...]'
    echo "Automatically generates secrets that have generators."
    echo ""
    echo 'OPTIONS:'
    echo '-h, --help                Show help'
    echo '-f, --force-generate      Force generating existing secrets'
    echo '-a, --add-to-git          Add generated secrets to git via git add.'
    echo '-t, --tags  TAGS          Additionally select all secrets matching any given tag.'
    echo '                            Takes a comma separated list of tags.'
  }

  FORCE_GENERATE=false
  WRITE_DEPHASH=${if writeDephash then "true" else "false"}
  ADD_TO_GIT=''${AGENIX_REKEY_ADD_TO_GIT-false}
  POSITIONAL_ARGS=()
  TAGS=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      "help"|"--help"|"-help"|"-h")
        show_help
        exit 1
        ;;
      "--force-generate"|"-f")
        FORCE_GENERATE=true
        ;;
      "--add-to-git"|"-a")
        ADD_TO_GIT=true
        ;;
      "--tags"|"-t")
        shift
        TAGS="$1"
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
  # $2: comma separated list of tags that match this secret
  function wants_secret() {
    if [[ ''${#POSITIONAL_ARGS[@]} -eq 0 ]] && [[ -z "$TAGS" ]]; then
      return 0
    else
      for secret in "''${POSITIONAL_ARGS[@]}" ; do
        [[ "$(${pkgs.coreutils}/bin/realpath -m "$1")" == "$(${pkgs.coreutils}/bin/realpath -m "$secret")" ]] && return 0
      done
      # Calculate the number of common lines in the splitted tags. Make sure to always include
      # the empty line so TAGS="" $2="" doesn't produce false positives. If more than one line
      # is returned, there is at least once matching tag.
      n_matching=$(comm -12 <(tr ',' '\n' <<< ",''${TAGS}," | sort -u) <(tr ',' '\n' <<< ",$2," | sort -u) | wc -l || echo 1)
      [[ "$n_matching" -gt 1 ]] && return 0
      return 1
    fi
  }

  if [[ ! -e flake.nix ]] ; then
    die "Please execute this script from your flake's root directory."
  fi

  KNOWN_SECRETS=(
    ${concatStringsSep "\n" (map (x: escapeShellArg x.sourceFile) (attrValues secretsWithContext))}
  )
  for secret in "''${POSITIONAL_ARGS[@]}" ; do
    for known in "''${KNOWN_SECRETS[@]}" ; do
      [[ "$(${pkgs.coreutils}/bin/realpath -m "$secret")" == "$(${pkgs.coreutils}/bin/realpath -m "$known")" ]] && continue 2
    done
    die "Provided path matches no known secret: $secret"
  done

  ${orderedGenerationCommands}

  # Remove orphaned files, first index all known files
  declare -A KNOWN_SECRETS_SET
  for known in "''${KNOWN_SECRETS[@]}" ; do
    # Mark secret as known
    KNOWN_SECRETS_SET["$known"]=true
  done

  # Iterate all files in generation directories and delete orphans
  (
    REMOVED_ORPHANS=0
    shopt -s nullglob
    for f in ${
      pkgs.lib.concatMapStringsSep " " (
        x: escapeShellArg (relativeToFlake x.config.age.rekey.generatedSecretsDir) + "/*.age"
      ) nodesWithGeneratedSecretsDir
    }; do
      if [[ "''${KNOWN_SECRETS_SET["$f"]-false}" == false ]]; then
        rm -- "$f" || true
        REMOVED_ORPHANS=$((REMOVED_ORPHANS + 1))
        if [[ "$ADD_TO_GIT" == true ]]; then
          git add "$f"
        fi
      fi
    done
    if [[ "''${REMOVED_ORPHANS}" -gt 0 ]]; then
      echo "[1;36m     Removed[m [0;33m''${REMOVED_ORPHANS} [0;36morphaned files in generation directories[m"
    fi
  )
''
