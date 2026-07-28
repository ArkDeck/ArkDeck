# TASK-UD-R2-RECAPTURE-001 — D2 readiness r1

## Classification

- Date:2026-07-28.
- Decision grade:D2 (E1 per-device typed capability evidence acceptance and
  named device-window arrangement).
- Base:current main `eaa57f9281c6194e1bada0c740bde1d6e4f48fc6`;
  r13 merge `f065ac90e69ff89c9ebb8817bfb4f9ebb1b0ed7d` (PR #711) is an
  ancestor. The sole intervening commit modifies only CHG-2026-042 tasks and
  has no overlap with this task, tool or schema input.
- Method:host-only governance, immutable-evidence and static-file audit.
- Draft effect:none. The task becomes ready only if the maintainer reviews and
  merges the exact readiness head.
- Installed-HDC process, HDC server lifecycle, device discovery, device,
  fixture, Recipe, raw-read, mutation and destructive dispatch:
  `0 / 0 / 0 / 0 / 0 / 0 / 0 / 0 / 0`.

## Dependency and harness closure

The following merged OIDs were read back:

- capture harness original/alignment/done:
  `7978fa761dcd8a38b7fea6ea040dac21147d1f2a`,
  `ba4b75b0c118a75af4415f9492f0c5e982ef138c`,
  `0b44d5998747c7737834f04cd00c3e8db352bab0`;
- echo remediation implementation/done and CAP-MUT ready restore:
  `b38d028ff821900c7c191c2bccc5951c5c719e7b`,
  `3ac44f2d759bd8bec8f95405b85281d70f89cad0`,
  `04e061e3328893b407d31ad83d19793973b02bd6`;
- Phase A evidence/done:
  `79b795b7916c863376b3c1f9c37456b0089283dd`,
  `d5aded75d30fbd7ae048005b692b7f4138b23055`;
- r12/r13:
  `d74c7af7179d89dc29c61e1e7b63d0ca4e7822ea`,
  `f065ac90e69ff89c9ebb8817bfb4f9ebb1b0ed7d`.

Current harness identity:

| File | Git blob | SHA-256 |
| --- | --- | --- |
| `scripts/ud_capture/README.md` | `f73f114a26319e9d0a01f4c2fcfa7b35c5a97ad1` | `6e5db1827176a0c16b5a4b21431efa9e4d4dab041f03801a357f74b3db2f2601` |
| `scripts/ud_capture/capture.py` | `0fae7eadbbf8a91c999c97eeb242f1d4cf8af653` | `b407aaa07260e3252428bdf00431f4d1e451c30f77c55f1f6b15a5d170d19492` |
| `scripts/ud_capture/test_capture.py` | `8d1428e47be07d14a47beaedbf667113366c14a7` | `b29c15b8fdca755f26fdfe4f5156082a8bb4a6fd80d8ceecec178419d4690070` |

The fixed Python 3.14.6 run passed all `63/63` harness tests. The command
registry remains at echo-remediation source OID
`b38d028ff821900c7c191c2bccc5951c5c719e7b`; no `scripts/**` byte changed.

## Exact target, tool and fixture pins

- HDC:
  `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`,
  registered `Ver: 3.2.0f`, SHA-256
  `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`.
  Static hash matched in this audit; no HDC process was started. Runtime version
  and hash remain mandatory `HP-0` gates.
- Device:the same physical DAYU200 (RK3568), serial SHA-256
  `958780b2ffb7090d4f22cdc1f547f9804ed0f0b605e3020f384e5d4823dc7a7e`,
  OpenHarmony `7.0.0.34`, API `26.0.0`, USB. This is a historical evidence pin,
  not a current-presence claim.
- Fixture:`entry-default-signed.hap`, `1512003` bytes, SHA-256
  `9453a396e81d55abfb05b4d7f9a512dea139e5843462051a6e1cc3586849fac8`;
  `com.example.waterflowdemo` / `EntryAbility`, versionCode `1000000`,
  compileSdk `26.0.0.25`, debug signed. Its real local path remains unknown to
  the Agent and absent from the repository.
- Hardware-evidence contract:blob
  `98443833b5bef36f4a1e0fdea9dbaaccf057f4d1`, schema `2.0.0`, SHA-256
  `d31fdb1d872567a7c4b69ee833593492adc9c39ce28b3b9b0f3597cc334628b0`.

## D2 capability acceptance candidate

On merge, the maintainer accepts Phase A hardware evidence
`EVD-UD-CAP-MUT-DAYU200-20260721-003` (#248) plus the #251 done state as
per-device typed capability evidence for only these required step kinds:

`toolchain-probe`, `target-inventory`, `fixture-install`, `fixture-start`,
`window-inventory`, `sidecar-inventory`, `ui-dump-capture`,
`remote-sidecar-capture`, `remote-sidecar-cleanup`, `fixture-stop`,
`fixture-uninstall`.

That evidence used HDC `3.2.0d`. The D2 acceptance is deliberately limited to
the same physical device/firmware and those device-side typed operations. It
does not infer that HDC `3.2.0f` has an equivalent output family, or that any
Recipe succeeds. Current client identity is separately pinned by r13 and must
pass `HP-0`; target/fixture/window/sidecar behavior must pass its own runtime
gate. Any difference stops the run without fallback or retry.

## Named window and storage predicate

- Operator:human maintainer `lvye` (fuhanfeng) only.
- Window:`UD-R2-RECAPTURE-DAYU200-20260728-001`.
- Eligibility:only after this exact D2 readiness head is merged.
- Start deadline:`2026-08-04T16:00:00Z`.
- Maximum runs:`1`; the first installed-HDC process dispatch consumes it.
- Exclusivity:one continuous device/session interval from `HP-0` through the
  retained-sidecar post-evidence recheck or truthful abort. No concurrent
  Agent or human HDC/device/flash/update/fixture action is permitted.

Before the first installed-HDC process, the human confirms the exact HAP is
available and creates a real session root outside every repository,
`/private/tmp`, `/private/var/tmp`, resolved `$TMPDIR`, teardown-owned and all
other ephemeral roots. The directory must be owner-only `0o700`; the received
sidecar must be exclusive-created `0o600`, regular and no-follow. The real path
never enters Git or the conversation.

Expiry, interruption, abort, attempted retry, concurrency, HDC/target/fixture/
schema/argv drift or a false storage predicate requires a new readiness. This
readiness contains no capture evidence and cannot itself consume the window.

## Verification

- Harness contract:`63/63` PASS.
- Fixed SDD interpreter:`<ARKDECK_ROOT>/.venv-sdd/bin/python`, Python `3.14.6`,
  PyYAML `6.0.3`.
- `scripts/check-sdd.sh`:`0` errors, `0` warnings, `111` acceptance IDs.
- Acceptance YAML parse, readiness-pin assertions and `git diff --check`:PASS.
- Repository-sensitive scan over this readiness record:zero raw serial,
  connect key, user-home path, resolved temporary path or controlled-root
  literal.
- No open PR touched the CHG-008 paths at draft start; unrelated work does not
  supply or change this task authority.
- This record is D2 readiness input, not device evidence, Recipe success,
  compatibility, support, conformance, capture completion or task done.
