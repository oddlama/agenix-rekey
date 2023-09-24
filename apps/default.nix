# XXX: this whole file is used for defineApps, which is deprecated and will
# be removed in the future (2024)
args: {
  edit-secret = {
    type = "app";
    program = "${import ./edit.nix args}/bin/agenix-edit";
  };
  rekey = {
    type = "app";
    program = "${import ./rekey.nix args}/bin/agenix-rekey";
  };
  generate-secrets = {
    type = "app";
    program = "${import ./generate.nix args}/bin/agenix-generate";
  };
}
