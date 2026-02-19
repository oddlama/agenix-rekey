if rekey_output="$(agenix rekey 2>&1)"; then
  echo "$rekey_output"
  echo "Expected agenix rekey to fail for out-of-flake rekeyFile path"
  exit 1
fi

echo "$rekey_output"
if ! grep -Fq "doesn't seem to be a direct subpath of the flake directory" <<< "$rekey_output"; then
  echo "Expected strict flake-root path validation error"
  exit 1
fi

if ! grep -Fq "age.secrets.<name>.rekeyFile" <<< "$rekey_output"; then
  echo "Expected remediation hint for rekeyFile path construction"
  exit 1
fi

echo "Strict outside-flake path validation works as expected"
exit 0
