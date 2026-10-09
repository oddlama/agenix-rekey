if ! rekey_output="$(agenix rekey 2>&1)"; then
  echo "$rekey_output"
  exit 1
fi
echo "$rekey_output"
if grep -Fq "without a proper context" <<< "$rekey_output"; then
  echo "Unexpected Nix string-context warning during local rekey"
  exit 1
fi

darwin_secret_file="$(nix eval --raw /tmp/test#darwinConfigurations.host-darwin.config.age.secrets.secret.file)"
if [[ -f "$darwin_secret_file" ]]; then
  echo "Darwin secret file exists at $darwin_secret_file"
else
  echo "Darwin secret file not found: $darwin_secret_file"
  exit 1
fi

agenixActivateNixOS
if [[ $(cat /run/agenix/secret) == "very good password" ]]; then
  echo "Decryption succeeded"
  exit 0
else
  echo "Wrong Decrypted value: "
  cat /run/agenix/secret
  exit 1
fi
