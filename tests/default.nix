{
  inputs,
  lib,
  self,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    let
      nixos-lib = import (pkgs.path + "/nixos/lib") { };
    in
    {
      checks =
        lib.flip lib.mapAttrs (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./cases))
          (
            name: _:
            let
              testFlake = ./cases/${name};
            in
            (nixos-lib.runTest {
              hostPkgs = pkgs;
              name = "agenix-rekey-test-${name}";
              #test = ../examples/flake-parts;
              # This speeds up the evaluation by skipping evaluating documentation (optional)
              defaults.documentation.enable = lib.mkDefault false;
              # This makes `self` available in the NixOS configuration of our virtual machines.
              # This is useful for referencing modules or packages from your own flake
              # as well as importing from other flakes.
              node.specialArgs = { inherit self; };
              nodes.node =
                { pkgs, ... }:
                {
                  environment.etc.setupScript = {
                    mode = "777";
                    source = pkgs.writeText "test" ''
                      cp -r ${testFlake} /tmp/test
                      chmod -R 777 /tmp/test
                      cd /tmp/test
                      ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ""
                      cp /etc/ssh/ssh_host_ed25519_key.pub ./host.pub
                      ls -lah /etc/ssh
                      export NIX_CONFIG="extra-experimental-features = flakes nix-command"
                      # Make sure to override all inputs to the exact input we have in our main testing flake to prevent any downloads in the VM
                      nix flake lock --offline --override-input agenix-rekey ${../.} ${
                        lib.concatMapAttrsStringSep " " (name: x: "--override-input ${name} ${x.outPath}") (
                          lib.filterAttrs (name: _: name != "self" && name != "agenix-rekey") inputs
                        )
                      }
                    '';
                  };
                  environment.etc.testScript = {
                    mode = "777";
                    source = lib.getExe (
                      pkgs.writeShellApplication {
                        name = "test";
                        runtimeInputs = [
                          # We don't actually use this. It's just to make sure the dependencies
                          # are in the nix store of the vm
                          # For writeshellapplication
                          pkgs.shellcheck-minimal
                          pkgs.stdenvNoCC
                          # For agenix
                          pkgs.rage
                          pkgs.age
                          pkgs.age-plugin-yubikey
                          # Add any other dependencies here
                        ];
                        text = ''
                          cd /tmp/test
                          echo "${pkgs.stdenv}" >&2
                          export NIX_CONFIG="extra-experimental-features = flakes nix-command"
                          DIR=$(mktemp -d)
                          # Wrap nix so it never tries to download anything
                          cat > "$DIR/nix" <<EOF
                            #!/usr/bin/env bash
                            /run/current-system/sw/bin/nix --offline "\$@"
                          EOF
                          chmod 777 "$DIR"
                          chmod 777 "$DIR/nix"
                          export PATH="$DIR:$PATH"

                          function agenix() {
                            nix run /tmp/test#packages.${system}.agenix "$@"
                          }
                          # shellcheck disable=SC2317
                          function agenixActivateNixOS() {
                            nix eval --raw /tmp/test#nixosConfigurations.host.config.system.activationScripts.agenixNewGeneration.text >> /run/agenix.sh
                            nix eval --raw /tmp/test#nixosConfigurations.host.config.system.activationScripts.agenixInstall.text >> /run/agenix.sh
                            # This command will exit because of a conditional in the last line
                            # This is intended and not a failure
                            (
                              set +e
                              bash /run/agenix.sh
                              true
                            )
                            rm /run/agenix.sh
                          }
                          ${builtins.readFile "${testFlake}/test.sh"}
                        '';
                      }
                    );
                  };
                };
              testScript = ''
                node.wait_for_unit("multi-user.target")
                outp = node.succeed("/etc/setupScript")
                print(outp)
                outp = node.succeed("/etc/testScript")
                print(outp)
              '';
            }).config.result
          );
    };
}
