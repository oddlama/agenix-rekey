{ pkgs }:
pkgs.runCommand "rekey-build"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.jq
      pkgs.python3
    ];
    buildScript = ../apps/rekey-build.sh;
  }
  ''
    python3 ${./rekey-build.py}
    touch "$out"
  ''
