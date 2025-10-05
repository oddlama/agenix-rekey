agenix rekey
agenixActivateNixOS
if [[ $(cat /run/agenix/secret) == "very good password" ]]; then
	echo "Decryption suceeded"
	exit 0
else
	echo "Wrong Decrypted value: "
	cat /run/agenix/secret
	exit 1
fi
