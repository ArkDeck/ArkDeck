# Rockchip signed Sandbox E0 probe

This harness builds a locally signed, Hardened Runtime, App Sandbox target with the same
six-entitlement shape as ArkDeck. The target opens `NSOpenPanel`; only the URL explicitly
selected there receives a security-scoped bookmark. Before process launch it checks the pinned
SHA-256, embedded signature integrity, and quarantine absence. Its only child argv is `ld`.

The harness never calls `sudo`, installs a helper/driver, changes an ACL/group/system rule,
switches device mode, or dispatches `ppt`/`wlx`/`rd`. The real-hardware window is E0/read-only.

Use a fresh output root outside the repository:

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
