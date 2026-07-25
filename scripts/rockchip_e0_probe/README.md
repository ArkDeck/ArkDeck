# Rockchip signed Sandbox E0 probe

This harness builds a locally signed, Hardened Runtime, App Sandbox target with the frozen
TASK-RKFUI-001F six-entitlement shape. The only changed permission from the historical #509
control is `user-selected.read-only` in place of `user-selected.read-write`; the executable-
writing entitlement and Info.plist quarantine overrides are forbidden. The target opens
`NSOpenPanel`; only the URL explicitly selected there receives a security-scoped bookmark.
Bookmark creation uses exactly `withSecurityScope + securityScopeAllowOnlyReadAccess`, while
resolution remains exactly `withSecurityScope + withoutUI`.
Before process launch it checks the pinned SHA-256, embedded signature integrity, and quarantine
absence. Its only possible child argv remains `ld`.

The harness never calls `sudo`, installs a helper/driver, changes an ACL/group/system rule,
switches device mode, or dispatches `ppt`/`wlx`/`rd`. TASK-RKFUI-001F authorizes only the
host-only `build-fixture`/`build`/`characterize` flow below. Using `run` with a real external
tool, USB, or device remains blocked pending a later D1 decision.

The generic E0 command shape remains documented for the later gated task. It is not authorized
by TASK-RKFUI-001F:

```text
python3 scripts/rockchip_e0_probe/probe.py build --output-root <fresh-absolute-root>
python3 scripts/rockchip_e0_probe/probe.py run \
  --app <root>/RockchipE0ProbeApp.app \
  --initial-directory <directory-containing-the-pinned-tool> \
  --receipt <root>/sanitized-receipt.json \
  --raw-root <root>/raw
```

The run command waits for the operator to choose `rkdeveloptool` in the system picker. Raw
stdout/stderr stay under the operator-controlled output root; the sanitized receipt replaces
the raw LocationID with a short SHA-256 summary and never records a full device serial.

If no Developer ID identity is provided, `build` uses an ad-hoc signature and records that
fact. This proves the local signed Sandbox access path, not Developer ID/notarization/release.

## TASK-RKFUI-001F read-only bookmark option remediation

Build the disposable fixture and two fresh signed App bundles beneath a fresh private-temp root:

```text
python3 scripts/rockchip_e0_probe/probe.py build-fixture \
  --output-root <private-temp-root>/fixture
python3 scripts/rockchip_e0_probe/probe.py build \
  --output-root <private-temp-root>/direct-app
python3 scripts/rockchip_e0_probe/probe.py build \
  --output-root <private-temp-root>/symlink-app
```

The fixture is compiled from `CharacterizationFixture.c` with deterministic linker inputs,
ad-hoc signed, checked as quarantine-absent, and given the required `rkdeveloptool` basename.
Its hash is deliberately different from the registry pin. The fixture binary, private path,
and raw xattr payload never enter the repository.

Run each selector in a separate App process and choose the single visible `rkdeveloptool` entry:

```text
python3 scripts/rockchip_e0_probe/probe.py characterize \
  --app <private-temp-root>/direct-app/RockchipE0ProbeApp.app \
  --fixture-root <private-temp-root>/fixture \
  --selector canonicalDirect \
  --receipt <private-temp-root>/direct-receipt.json \
  --raw-root <private-temp-root>/direct-raw

python3 scripts/rockchip_e0_probe/probe.py characterize \
  --app <private-temp-root>/symlink-app/RockchipE0ProbeApp.app \
  --fixture-root <private-temp-root>/fixture \
  --selector singleLayerSymlink \
  --receipt <private-temp-root>/symlink-receipt.json \
  --raw-root <private-temp-root>/symlink-raw
```

A passing remediation requires both receipts to report successful bookmark/security
scope, `executableHashMismatch`, unchanged signature and bytes, quarantine absent before and
after, and every selected-process/device/network/mutation/xattr-write counter at zero. The
wrong-hash gate therefore prevents the fixture from executing. A symlink selection may be
lexically canonicalized by `NSOpenPanel`; that is recorded but is not a failure when the
returned URL resolves to the exact fixture target. This is host-only platform evidence, not
real-tool, USB, device, or product-delivery evidence.
