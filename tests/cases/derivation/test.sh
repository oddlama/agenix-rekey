if ! rekey_output="$(agenix rekey 2>&1)"; then
  echo "$rekey_output"
  exit 1
fi
echo "$rekey_output"
if grep -Fq "without a proper context" <<< "$rekey_output"; then
  echo "Unexpected Nix string-context warning during derivation rekey"
  exit 1
fi

if ! out_paths="$(agenix rekey --show-out-paths 2>&1)"; then
  echo "$out_paths"
  exit 1
fi
if grep -Fq "without a proper context" <<< "$out_paths"; then
  echo "Unexpected Nix string-context warning while listing derivation out paths"
  exit 1
fi
if [[ -z "$out_paths" ]]; then
  echo "No derivation out paths were returned"
  exit 1
fi
while read -r path; do
  [[ -z "$path" ]] && continue
  if [[ "$path" != /nix/store/* ]]; then
    echo "Invalid derivation out path: $path"
    exit 1
  fi
done <<< "$out_paths"

if ! drv_paths="$(agenix rekey --show-drv-paths 2>&1)"; then
  echo "$drv_paths"
  exit 1
fi
if grep -Fq "without a proper context" <<< "$drv_paths"; then
  echo "Unexpected Nix string-context warning while listing derivation drv paths"
  exit 1
fi
if [[ -z "$drv_paths" ]]; then
  echo "No derivation drv paths were returned"
  exit 1
fi
while read -r path; do
  [[ -z "$path" ]] && continue
  if [[ "$path" != /nix/store/*.drv ]]; then
    echo "Invalid derivation drv path: $path"
    exit 1
  fi
done <<< "$drv_paths"

agenixActivateNixOS
if [[ $(cat /run/agenix/secret) == "very good password" ]]; then
  echo "Decryption succeeded"
  exit 0
else
  echo "Wrong decrypted value:"
  cat /run/agenix/secret
  exit 1
fi
