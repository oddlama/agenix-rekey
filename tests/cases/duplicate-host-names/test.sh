if ! rekey_output="$(agenix rekey 2>&1)"; then
  echo "$rekey_output"
  exit 1
fi
echo "$rekey_output"

if ! grep -Fq "nixos:host" <<< "$rekey_output"; then
  echo "Expected namespaced nixos host label in output"
  exit 1
fi
if ! grep -Fq "darwin:host" <<< "$rekey_output"; then
  echo "Expected namespaced darwin host label in output"
  exit 1
fi

nixos_secret_file="$(nix eval --raw /tmp/test#nixosConfigurations.host.config.age.secrets.secret.file)"
darwin_secret_file="$(nix eval --raw /tmp/test#darwinConfigurations.host.config.age.secrets.secret.file)"

if [[ "$nixos_secret_file" == "$darwin_secret_file" ]]; then
  echo "NixOS and Darwin secret paths unexpectedly collide"
  exit 1
fi

if [[ ! -f "$nixos_secret_file" ]]; then
  echo "NixOS secret file not found: $nixos_secret_file"
  exit 1
fi
if [[ ! -f "$darwin_secret_file" ]]; then
  echo "Darwin secret file not found: $darwin_secret_file"
  exit 1
fi

agenixActivateNixOS
if [[ $(cat /run/agenix/secret) == "very good password" ]]; then
  echo "Decryption succeeded"
  exit 0
else
  echo "Wrong decrypted value:"
  cat /run/agenix/secret
  exit 1
fi
