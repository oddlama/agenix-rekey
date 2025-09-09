# Ask the store rather than inferring trust from the client configuration or USER.
# Older Nix versions and some stores do not report trust. In that case, keep
# the original build behavior and let Nix decide whether overrides are allowed.
sandbox_args=(--extra-sandbox-paths "${!SANDBOX_PATHS[*]}")
if store_info=$(nix store ping --json); then
  if store_trust=$(jq -er '
    if (.trusted | type) == "boolean" then .trusted | tostring
    else error("store did not report boolean trust") end
  ' <<< "$store_info"); then
    if [[ "$store_trust" == false ]]; then
      # Only the daemon knows its effective sandbox configuration. Do not reject
      # builds based on client sandbox-paths: sandboxing may even be disabled.
      sandbox_args=()
    fi
  else
    echo "Warning: Could not determine store trust; retaining sandbox overrides." >&2
  fi
else
  echo "Warning: Could not query store trust; retaining sandbox overrides." >&2
fi
nix build --no-link "${sandbox_args[@]}" --impure "${DRVS_TO_BUILD[@]}"
