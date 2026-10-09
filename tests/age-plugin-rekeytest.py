"""Test-only age plugin: stores file keys in plaintext. NEVER use for real secrets."""

import sys


def receive():
    header = sys.stdin.readline().strip().split()
    assert header and header[0] == "->", header
    body = ""
    while True:
        line = sys.stdin.readline().rstrip("\n")
        body += line
        if len(line) < 64:
            return header[1:], body


def send(command, body=""):
    print(f"-> {command}\n{body}", flush=True)


mode = sys.argv[1]
assert mode in ("--age-plugin=recipient-v1", "--age-plugin=identity-v1")
responses = []
while True:
    args, body = receive()
    if args[0] == "done":
        break
    if mode == "--age-plugin=recipient-v1" and args[0] == "wrap-file-key":
        responses.append((f"recipient-stanza {len(responses)} rekeytest", body))
    if mode == "--age-plugin=identity-v1" and args[0] == "recipient-stanza":
        if args[2] == "rekeytest":
            responses.append((f"file-key {args[1]}", body))

for command, body in responses:
    send(command, body)
    assert receive() == (["ok"], "")
send("done")
