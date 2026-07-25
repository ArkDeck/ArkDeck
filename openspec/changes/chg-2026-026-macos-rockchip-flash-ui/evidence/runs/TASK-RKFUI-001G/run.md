# TASK-RKFUI-001G — blocked Stage A run

- Date: 2026-07-25
- Executor: agent
- Platform: macOS 26.5.2 arm64; macOS SDK 26.5
- Evidence class: signed Sandbox, host-only external-fixture characterization
- Verdict: **blocked**
- Sanitized receipt:
  `blocked-stage-a-selector-2026-07-25.json`
- Receipt SHA-256:
  `240503c81b9f5a7f9d3e7e4fbb6be806f1417992d7fa52bcc3dd47af1b6d5d8e`

## Readiness and input closure

PR #522 was approved by `lvye` at exact head
`7e4bb944ca5787f56af60fa5ab8ca17614842db6` and merged as
`27796f52734a844f1cda0e0ed2c9113abb83d39e`. Work began from that merge OID.
The r9-pinned Probe/App entitlement/ADR/platform inputs were rechecked before
the run and matched their declared blobs. Concurrent PRs #523 and #524 had no
path overlap with this task.

The candidate Stage A build used the exact product six-entitlement set,
Hardened Runtime, an ad-hoc signature, the production registry hash as its
compile-time wrong-hash pin, and no runtime hash/path/argv/environment input.
Its fresh canonical `rkdeveloptool` fixture was a deterministic, no-UUID,
ad-hoc-signed, quarantine-absent `return 0` executable. The fixture hash
`56007f66978b3f8e012569482c660120fc4574aac6849c934cc8ef4e1f24b557`
did not match the production registry pin. Linked/import closure contained
only `/usr/lib/libSystem.B.dylib`, with no libusb, IOKit, network, shell, or
process-spawn import.

## Commands

Private paths are intentionally replaced with placeholders.

```text
python3 -m py_compile scripts/rockchip_e0_probe/probe.py scripts/rockchip_e0_probe/test_probe.py
python3 -m unittest scripts/rockchip_e0_probe/test_probe.py -v
python3 scripts/rockchip_e0_probe/probe.py build-launch-stage \
  --stage A --output-root <private-temp-root>/stage-a
python3 scripts/rockchip_e0_probe/probe.py characterize-launch \
  --stage A \
  --app <private-temp-root>/stage-a/app/RockchipE0ProbeApp.app \
  --fixture-root <private-temp-root>/stage-a/fixture \
  --receipt <private-temp-root>/stage-a-receipt.json \
  --raw-root <private-temp-root>/stage-a-raw
```

Candidate static/unit tests passed 15/15 before the run. They are not acceptance
evidence and the candidate implementation was not retained.

## Observed result

The system picker run completed selection but the selected entry failed the
canonical regular-file gate as `selectedEntryNotRegularFile`. The run stopped
before security-scope, bookmark, hash, signature, quarantine, or Process
dispatch. Selected fixture process and fixture-`ld` counts were both zero.
Stage B fixture/App build and Stage B process dispatch were zero.

The candidate envelope reused a generic post-bookmark failure emitter and
incorrectly reported `bookmarkCreated=true`, although this failure branch is
before bookmark creation. The repository receipt explicitly corrects the
observation to bookmark creation/resolution dispatch count zero and records
the envelope-contract mismatch as an additional gate failure. This mismatch
also independently disqualifies the candidate.

Fixture bytes, size, CDHash, signature validity, and quarantine state were
unchanged. Real tool/`ld`, network, USB, HDC, device, E1/E2, mutation,
destructive, privilege, helper, install, system-rule, group, ACL, and xattr
write counters were all zero. No full path, bookmark bytes, raw xattr,
Sandbox log, or fixture binary is committed.

## AC conclusion and handoff

- `AC-UX-007-01`: host-only product-shape characterization is honestly
  **blocked** at the Stage A selector contract; zero external/device effects
  are evidenced.
- `AC-FLASH-001-01`: not advanced. Neither fixture `ld` nor real
  `rkdeveloptool ld` ran.
- TASK-RKFUI-001G is not marked done and TASK-RKFUI-001 remains blocked.
- Per r9, there is no retry, Stage B, symlink/alias fallback, entitlement
  expansion, copy/bundle/helper path, or real-tool/device attempt. All candidate
  implementation files were removed. The next technical direction requires an
  independent ADR/change proposal.
