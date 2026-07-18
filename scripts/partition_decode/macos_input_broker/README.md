# macOS trusted input broker

This directory is the independent TASK-PD-001 r2 input-boundary artifact. It is
not linked into `ArkDeckApp` and makes no distribution or support claim.

Trust chain:

```text
signed App Sandbox artifact
  → NSOpenPanel / PowerBox user selection
  → reject standardized /dev namespace
  → O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC
  → same-process CPython C API call(fd only)
  → decoder fstat + F_GETFL before first read
```

`Broker.entitlements` is the complete entitlement allowlist. `policy.json` is
the reviewable source policy. `main.m` has one archive-open target, reached only
from the selected `NSURL`; it has no runtime argument path, subprocess, socket,
network client, IOKit, USB or serial path. The live policy inspection uses
`sandbox_check` only; it does not open a device node.

The threat model trusts the macOS kernel, code-signing, App Sandbox and PowerBox.
A compromised kernel/root is out of scope. Under that boundary, device nodes
cannot be created in a user-writable selected directory by the modeled attacker;
direct `/dev` selection is rejected before open, and final symlinks are rejected
by `O_NOFOLLOW`.

The local broker artifact targets macOS 26.0 because the readiness-pinned
CPython 3.14.6 framework was built for macOS 26.0. This is platform evidence on
the recorded host tuple, not a product minimum-version or support declaration.

`collect_platform_evidence.py` accepts only `--out-dir`. It builds a fresh
artifact in a private temporary directory and independently runs strict
codesign verification, entitlement inspection, linked-library inspection and a
complete signed-bundle file manifest before launch. It launches that exact
executable with a fixed argv and `shell=False`, captures a locator-free runtime
receipt through its stdout pipe, verifies the receipt's running CDHash and core
output hashes, and repeats artifact inspection after exit. It then invokes the
in-process create-only publisher; only a successful closed validation creates
the evidence directory. There is no CLI that publishes caller-supplied JSON.

The runtime receipt gets Python 3.14.6 from the embedded interpreter's
`sys.version_info`, so host
`/usr/bin/python3` is neither queried nor trusted. The receipt and platform
evidence include no archive locator and no parameter raw text.
