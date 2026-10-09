assert_before() {
  local output=$1
  local first=$2
  local second=$3
  local first_line second_line

  first_line=$(grep -n -m1 -F "$first" <<< "$output" | cut -d: -f1)
  second_line=$(grep -n -m1 -F "$second" <<< "$output" | cut -d: -f1)
  if [[ -z "$first_line" || -z "$second_line" || "$first_line" -ge "$second_line" ]]; then
    echo "Expected '$first' before '$second'"
    echo "$output"
    exit 1
  fi
}

if ! rekey_output=$(agenix rekey 2>&1); then
  echo "$rekey_output"
  exit 1
fi
echo "$rekey_output"
assert_before "$rekey_output" 'Planned operations:' 'Master identity session started.'
assert_before "$rekey_output" 'Master identity session started.' 'Rekeying'

if ! update_output=$(agenix update-masterkeys 2>&1); then
  echo "$update_output"
  exit 1
fi
echo "$update_output"
assert_before "$update_output" 'Planned operations:' 'Master identity session started.'
assert_before "$update_output" './secret.age' 'Master identity session started.'

help_output=$(agenix update-masterkeys --help 2>&1)
if grep -Fq 'Master identity session started.' <<< "$help_output"; then
  echo 'Help unexpectedly started a master identity session.'
  exit 1
fi

# Updating the source ciphertext changes local rekey output paths.
agenix rekey

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
