"""Run the production build fragment with a recording Nix store double.

Configuration is deliberately unavailable: only the store can decide whether its
sandbox exposes a path. These tests verify delegation, not Nix sandbox semantics.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


script = str(Path(os.environ["buildScript"]).resolve())
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    nix = root / "nix"
    nix.write_text(f"#!{sys.executable}\n" + """import json
import os
import sys
with open(os.environ['CALLS'], 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1:] == ['store', 'ping', '--json']:
    print(os.environ['STORE_INFO'])
    if os.environ['PING_STATUS'] != '0':
        print('store query failed', file=sys.stderr)
    sys.exit(int(os.environ['PING_STATUS']))
if sys.argv[1] == 'build':
    sys.exit(int(os.environ['BUILD_STATUS']))
raise SystemExit('client configuration must not be queried')
""")
    nix.chmod(0o755)

    def check(name, info, *, override, path="/tmp/cache", ping=0, status=0, warning=False):
        calls = root / "calls"
        calls.write_text("")
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", '''
                declare -A SANDBOX_PATHS=(["$CACHE_PATH"]=1)
                DRVS_TO_BUILD=('/nix/store/first.drv^*' '/nix/store/second.drv^*')
                source "$buildScript"
            '''],
            env=os.environ | {
                "PATH": f"{root}:{os.environ['PATH']}",
                "CALLS": str(calls),
                "STORE_INFO": json.dumps(info) if not isinstance(info, str) else info,
                "PING_STATUS": str(ping),
                "BUILD_STATUS": str(status),
                "CACHE_PATH": path,
                "buildScript": script,
                # A forged USER must not affect store-reported trust.
                "USER": "root",
            },
            capture_output=True,
            text=True,
            timeout=30,
        )
        expected = ["build", "--no-link"]
        if override:
            expected += ["--extra-sandbox-paths", path]
        expected += ["--impure", "/nix/store/first.drv^*", "/nix/store/second.drv^*"]
        assert result.returncode == status, (name, result)
        assert [json.loads(line) for line in calls.read_text().splitlines()] == [
            ["store", "ping", "--json"], expected
        ], name
        assert ("Warning:" in result.stderr) == warning, (name, result.stderr)
        if ping:
            assert "store query failed" in result.stderr, name

    for name in ("explicit trusted user", "@group trust", "wildcard trust", "local store"):
        check(name, {"trusted": True}, override=True)
    for name, path in (
        ("untrusted despite USER=root", "/tmp/cache"),
        ("daemon paths differ from client", "/tmp/cache"),
        ("sandbox=false, no configured paths (including macOS)", "/tmp/cache"),
        ("literal brackets", "/tmp/cache[1]"),
        ("identity mapping /tmp/cache=/tmp/cache", "/tmp/cache"),
        ("configured trailing slash /tmp/cache/", "/tmp/cache"),
        ("optional configured path /tmp/cache?", "/tmp/cache"),
    ):
        check(name, {"trusted": False}, override=False, path=path)

    # A daemon rejection must propagate, including when a regex lookalike path
    # (/tmp/agenix-rekeyX1000) does not expose /tmp/agenix-rekey.1000.
    check("literal dot, daemon rejects build", {"trusted": False}, override=False,
          path="/tmp/agenix-rekey.1000", status=17)
    for info in ({}, {"trusted": None}, {"trusted": "false"}, "not json", ""):
        check("inconclusive trust", info, override=True, warning=True)
    check("query failure", {"trusted": False}, ping=1, override=True, warning=True)
    check("trusted build failure", {"trusted": True}, override=True, status=19)

print("Store trust, sandbox delegation, fallback and build failure regressions passed.")
