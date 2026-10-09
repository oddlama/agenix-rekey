{ pkgs }:
let
  makeDerivation =
    requiredSystemFeatures:
    import ../nix/output-derivation.nix {
      appHostPkgs = pkgs;
      hostConfig = {
        networking.hostName = "required-system-features-test";
        age = {
          rekey = {
            inherit requiredSystemFeatures;
            cacheDir = "/tmp/agenix-rekey-test";
            hostPubkey = "age12wqn07q59cgn8258mt3la3ym7nr2cdnh86gp03f6dnm9k3zaqvpq73ny7c";
          };
          secrets.test = {
            name = "test";
            rekeyFile = ./cases/simple/secret.age;
            generator = null;
            intermediary = false;
          };
        };
      };
    };

  features = [
    "agenix-rekey"
    "custom-feature"
  ];
  defaultDerivation = makeDerivation [ ];
  configuredDerivation = makeDerivation features;
  # mkDerivation ignores null attributes, reproducing the previous omission.
  withoutFeatures = configuredDerivation.overrideAttrs (_: {
    requiredSystemFeatures = null;
  });
in
assert pkgs.lib.assertMsg (
  defaultDerivation.drvPath == withoutFeatures.drvPath
  && defaultDerivation.outPath == withoutFeatures.outPath
) "Empty requiredSystemFeatures must preserve the existing derivation and output paths";
assert pkgs.lib.assertMsg (
  configuredDerivation.requiredSystemFeatures == features
) "Nonempty requiredSystemFeatures must be forwarded to the derivation";
assert pkgs.lib.assertMsg (
  configuredDerivation.drvPath != defaultDerivation.drvPath
) "Nonempty requiredSystemFeatures must affect the derivation path";
pkgs.runCommand "required-system-features-check" { } ''
  touch "$out"
''
