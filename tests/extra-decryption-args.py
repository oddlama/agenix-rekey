"""Regression tests for extraDecryptionArgs (run by the Nix check)."""

import json
import os
from pathlib import Path
import shlex
import subprocess


data = json.loads(os.environ["testData"])
os.environ["RECORD_ARGS"] = str(Path("args.bin").resolve())
for variable in ("AGENIX_REKEY_PRIMARY_IDENTITY", "AGENIX_REKEY_PRIMARY_IDENTITY_ONLY"):
    os.environ.pop(variable, None)


def run(command, args=(), *, env=None, plaintext=None):
    return subprocess.run(
        shlex.split(command) + list(args),
        env=os.environ | (env or {}),
        input=plaintext,
        stdout=subprocess.PIPE,
        check=True,
        timeout=30,
    ).stdout


def recorded():
    return Path("args.bin").read_bytes().decode().split("\0")[:-1]


identities = ["-i", "/test-identity", "-i", "/unused-identity"]
primary = {"AGENIX_REKEY_PRIMARY_IDENTITY": "second-recipient"}
primary_only = primary | {"AGENIX_REKEY_PRIMARY_IDENTITY_ONLY": "true"}
trailing = ["-o", "output with spaces", "input.age"]
for name, extra in (("defaults", []), ("extra", data["extraDecryptionArgs"])):
    commands = data[name]
    for env, expected in (
        ({}, identities),
        (primary, ["-i", "/unused-identity"] + identities),
        (primary_only, ["-i", "/unused-identity"]),
    ):
        run(commands["decrypt"], trailing, env=env)
        assert recorded() == ["-d"] + expected + extra + trailing, recorded()
        run(commands["encrypt"], trailing, env=env)
        assert recorded() == ["-e", "-r", data["pubkey"], "-r", "second-recipient"] + trailing

# Run an app through both public entry points, with and without extra arguments.
Path("flake.nix").touch()
secret = "secret with spaces.age"
Path(secret).touch()
for app in data["apps"]:
    for env, expected in (({}, identities), (primary_only, ["-i", "/unused-identity"])):
        run(app["program"], app["arguments"] + [secret], env=env | {"EDITOR": "true"})
        actual = recorded()
        assert actual[:-3] == ["-d"] + expected + app["extra"], actual
        assert actual[-3] == "-o" and actual[-1] == secret, actual

assert not Path("unexpected").exists(), "extra arguments were interpreted as shell code"

# Real age and rage execute a test-only plugin via -j with no identity files.
# This also checks plugin PATH setup and encryption without decryption arguments.
plaintext = b"implicit plugin round-trip\n"
for commands in data["plugins"]:
    encrypted = run(commands["encrypt"], plaintext=plaintext)
    decrypted = run(commands["decrypt"], plaintext=encrypted)
    assert decrypted == plaintext, decrypted

print("Argument escaping, both configuration entry points, primary-only mode and age/rage plugin round-trips passed.")
