agenix rekey

out_paths="$(agenix rekey --show-out-paths)"
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

drv_paths="$(agenix rekey --show-drv-paths)"
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
