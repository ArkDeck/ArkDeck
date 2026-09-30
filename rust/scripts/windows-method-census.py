#!/usr/bin/env python3
"""Ask a Windows development daemon every published control method.

The daemon (`arkdeck-agentd.exe`, the path given) is started over a fresh
isolated development root below the temporary directory, with every
`ARKDECK_`/`OHOS_HDC_` input removed but that root: nothing installed is read
or written, and no HDC, device or ArkTrace distribution is involved. Each
method is sent on its own pipe connection with the parameters of each request
the committed control-frame corpus records for it
(`Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames`), in
order, until one is not refused as malformed (`invalidParams`); a method the
corpus records no request for is sent with none. The last reply is
classified:

- `result`: answered with a result;
- `ownerRefusal`: refused by an owner the daemon composes (its own
  validation of the recorded parameters, the recorded reference not found
  here, or a dependency owner it names that is not composed);
- `noOwner`: refused because no owner for the method is composed (the
  control layer's or the host's "not configured"/"unavailable" answer);
- `requestRefused`: every recorded request refused before any owner was
  reached (`invalidParams`), so this census cannot tell;
- `nonConforming`: the control layer replaced an answer that does not
  conform to the method's published contract (`internalError`), a defect
  to look at rather than an answer.

The pipe is opened as a plain file: this measures what the daemon answers, not
the product client's identity check, which the signed CLI tests hold. Prints
one JSON document: the owners the daemon reports, the Catalog operations
`operation.list` names available, the counts and every method's reply code,
message and class. Windows only.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CONTRACT = ROOT / "Packages/ArkDeckKit/Contracts/control-protocol.json"
CORPUS = ROOT / "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames"

# The control layer's and the host's answers for a method whose owner is not
# composed: "... not configured", the read-only foundation's refusal, and the
# named owners' "unavailable".
NO_OWNER = re.compile(
    r"(not configured|unavailable in the read-only Rust foundation"
    r"|^workspace project owner is unavailable$|^Trace inspection is unavailable$"
    r"|^Import owner services are unavailable$|^hdc[.]notConfigured$)"
)


def recorded_params(method: str) -> list:
    path = CORPUS / f"{method}.jsonl"
    if not path.exists():
        return [{}]
    params = []
    for line in path.read_text(encoding="utf-8").splitlines():
        value = json.loads(line).get("params", {})
        if value not in params:
            params.append(value)
    return params or [{}]


def classify(reply: dict) -> str:
    if reply.get("ok") is True:
        return "result"
    error = reply.get("error", {})
    if error.get("message") == "the result does not conform to the current contract":
        return "nonConforming"
    if NO_OWNER.search(error.get("message", "")):
        return "noOwner"
    if error.get("code") == "invalidParams":
        return "requestRefused"
    return "ownerRefusal"


def exchange(pipe: str, identity: str, version: str, method: str, params, index: int) -> dict:
    frame = {
        "protocolVersion": version,
        "contractIdentity": identity,
        "id": f"census-{index}",
        "method": method,
        "params": params,
    }
    newline = bytes([10])
    with open(pipe, "r+b", buffering=0) as connection:
        connection.write(json.dumps(frame).encode() + newline)
        reply = b""
        while not reply.endswith(newline):
            chunk = connection.read(1)
            if not chunk:
                break
            reply += chunk
    return json.loads(reply)


def main() -> int:
    if os.name != "nt" or len(sys.argv) != 2:
        print("usage (Windows): windows-method-census.py <arkdeck-agentd.exe>", file=sys.stderr)
        return 2
    contract = json.loads(CONTRACT.read_text(encoding="utf-8"))
    identity = hashlib.sha256(
        json.dumps(contract, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    temporary = Path(tempfile.mkdtemp(prefix="ad-census-")).resolve()
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.upper().startswith(("ARKDECK_", "OHOS_HDC_"))
    }
    environment["ARKDECK_DEVELOPMENT_STATE_ROOT"] = str(temporary)
    daemon = subprocess.Popen(
        [sys.argv[1]],
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        pipe = None
        owners = None
        for line in daemon.stdout:
            if line.startswith("arkdeck-agentd owners: "):
                owners = line.strip().removeprefix("arkdeck-agentd owners: ")
            if line.startswith("arkdeck-agentd listening on "):
                pipe = line.strip().removeprefix("arkdeck-agentd listening on ")
                break
        if pipe is None:
            print(daemon.stderr.read(), file=sys.stderr)
            return 1
        listed = exchange(pipe, identity, contract["currentVersion"], "operation.list", {}, -1)
        available = sorted(
            operation["reference"]
            for operation in listed.get("result", [])
            if operation.get("availability") == "available"
        )
        rows = []
        for method in contract["methods"]:
            for params in recorded_params(method):
                answer = exchange(
                    pipe, identity, contract["currentVersion"], method, params, len(rows)
                )
                if answer.get("error", {}).get("code") != "invalidParams":
                    break
            error = answer.get("error", {})
            rows.append(
                {
                    "method": method,
                    "class": classify(answer),
                    "code": error.get("code"),
                    "message": error.get("message"),
                }
            )
        counts: dict[str, int] = {}
        for row in rows:
            counts[row["class"]] = counts.get(row["class"], 0) + 1
        print(
            json.dumps(
                {
                    "owners": owners,
                    "operationsAvailable": available,
                    "operationsListed": len(listed.get("result", [])),
                    "methods": len(rows),
                    "counts": counts,
                    "rows": rows,
                },
                indent=2,
            )
        )
        return 0
    finally:
        daemon.kill()
        daemon.wait()


if __name__ == "__main__":
    sys.exit(main())
