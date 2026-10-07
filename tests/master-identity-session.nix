{ pkgs }:
let
  configuredPlugin = pkgs.writeShellScriptBin "age-plugin-session-test" ''
    echo configured-plugin
  '';
  ambientPlugin = pkgs.writeShellScriptBin "age-plugin-session-test" ''
    echo ambient-plugin
  '';
  mockAge = pkgs.writeShellScriptBin "mock-age" ''
    set -euo pipefail
    value=$(age-plugin-session-test)
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == -o ]]; then
        shift
        printf '%s\n' "$value" > "$1"
        exit 0
      fi
      shift
    done
    printf '%s\n' "$value"
  '';
  wrapper = pkgs.writeShellScriptBin "mock-master-session" ''
    set -euo pipefail
    [[ "$1" == -- ]]
    shift
    echo 'Master identity session started.'
    echo session >> "$SESSION_WRAPPER_LOG"
    exec "$@"
  '';
  fixture = pkgs.runCommand "master-session-fixture" { } ''
    mkdir "$out"
    echo '{}' > "$out/flake.nix"
    echo 'test ciphertext without real secrets' > "$out/secret.age"
  '';
  inputsFor = sessionWrapper: {
    inherit pkgs;
    userFlake.outPath = fixture;
    agePackage = _: mockAge;
    nodes.host.config.age = {
      rekey = {
        agePlugins = [ configuredPlugin ];
        masterIdentities = [ ];
        masterIdentitySessionWrapper = sessionWrapper;
        storageMode = "local";
        hostPubkey = "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq";
      };
      secrets.secret.rekeyFile = "${fixture}/secret.age";
    };
  };
  inputs = inputsFor wrapper;
  rekey = import ../apps/rekey.nix inputs;
  updateMasterkeys = import ../apps/update-masterkeys.nix inputs;
  unwrappedRekey = import ../apps/rekey.nix (inputsFor null);
  utils = import ../nix/lib.nix inputs;
in
pkgs.runCommand "master-identity-session" { } ''
  cp -r ${fixture}/. .
  chmod u+w secret.age
  export SESSION_WRAPPER_LOG="$PWD/session.log"
  export PATH=${ambientPlugin}/bin:${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin
  : > "$SESSION_WRAPPER_LOG"

  assert_before() {
    first_line=$(grep -n -m1 -F "$2" <<< "$1" | cut -d: -f1)
    second_line=$(grep -n -m1 -F "$3" <<< "$1" | cut -d: -f1)
    [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]]
  }

  output=$(${rekey}/bin/agenix-rekey --dummy)
  assert_before "$output" 'End of plan.' 'Master identity session started.'
  [[ $(wc -l < "$SESSION_WRAPPER_LOG") -eq 1 ]]

  : > "$SESSION_WRAPPER_LOG"
  output=$(${updateMasterkeys}/bin/agenix-update-masterkeys)
  assert_before "$output" './secret.age' 'Master identity session started.'
  assert_before "$output" 'End of plan.' 'Master identity session started.'
  [[ $(wc -l < "$SESSION_WRAPPER_LOG") -eq 1 ]]
  [[ $(cat secret.age) == configured-plugin ]]
  [[ $(${utils.ageHostEncrypt inputs.nodes.host}) == configured-plugin ]]

  : > "$SESSION_WRAPPER_LOG"
  ${updateMasterkeys}/bin/agenix-update-masterkeys --help
  if ${rekey}/bin/agenix-rekey --help; then
    echo 'Rekey help unexpectedly changed its exit status.' >&2
    exit 1
  fi
  ${rekey}/bin/agenix-rekey --show-out-paths
  ${rekey}/bin/agenix-rekey --show-drv-paths
  ${unwrappedRekey}/bin/agenix-rekey --dummy
  [[ ! -s "$SESSION_WRAPPER_LOG" ]]

  touch "$out"
''
