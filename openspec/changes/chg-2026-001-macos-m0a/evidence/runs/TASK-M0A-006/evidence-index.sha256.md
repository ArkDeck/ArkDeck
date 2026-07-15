# TASK-M0A-006 evidence SHA-256 index

- Index scope: authoritative inputs and pre-existing evidence consumed by the
  TASK-M0A-006 rollup
- Source revision: `0abbbaa1a6af080a94b7222ba67f4e7a3f325ab0`
- Hash algorithm: SHA-256 over the exact file bytes in the working tree at that
  revision
- Generated: 2026-07-15

## Authoritative inputs

| SHA-256 | Path |
| --- | --- |
| `6ed7ae92343f93693555fef4e5831cd363f6d0c5dcb7fbdd4d651d6d506a1212` | `openspec/platforms/PLATFORM-PROFILES.lock.yaml` |
| `54bd9b295799cb8d93bf397eeb585f24828463f4f1fce1e59a0693f65369d0bf` | `openspec/platforms/macos/profile.md` |
| `0e3de8749ec5e974ed96ceed1760ee7e049a92eecb052c2cfb47658390ca7072` | `openspec/platforms/macos/verification.md` |
| `0502fb2d7a2807f3d99c61b4db90f5e8f7963a80cc6a225f541cfe7f8613178b` | `openspec/platforms/macos/conformance-cases.yaml` |
| `ea4e89905abc02717049a651356ecfe6148ea85e820a7d442aa06686c1a52f04` | `openspec/integrations/INTEGRATION-PROFILES.lock.yaml` |
| `820eca652a7e237693960aadc6d01a9f45c4a964cff3d8307a8fa0e4e5218734` | `openspec/integrations/openharmony/profile.md` |
| `686289693cd4052b5000e330951d9ac5297b72b6529ef8427dae40e0c32c8e55` | `openspec/changes/chg-2026-001-macos-m0a/proposal.md` |
| `a531e0df7353e75712ba89ad4c74f8a010ce6ebea9368c33538e45ab44611143` | `openspec/changes/chg-2026-001-macos-m0a/tasks.md` |
| `99cfdb8e0ea890fc89a2a98e19544e6003cd481292e6b3f68e96966dfbdc5e48` | `openspec/changes/chg-2026-001-macos-m0a/verification.md` |

## Source task evidence

| SHA-256 | Path |
| --- | --- |
| `195e17375afb6678261a619359e7ed4cf5cf61bb4c031eea3ad366ddd893c6c8` | `openspec/changes/chg-2026-001-macos-m0a/evidence/runs/TASK-M0A-001/run.md` |
| `600f1018f9d2954c8c0946794a5fc16f11912aecbce3da7e3d5c4569db9e8fbf` | `openspec/changes/chg-2026-001-macos-m0a/evidence/runs/TASK-M0A-002/run.md` |
| `737ea09a64ca7f69d9b6ae2f7ede54a8542b166faa88be6ca9bca53a998f1d95` | `openspec/changes/chg-2026-001-macos-m0a/evidence/runs/TASK-M0A-003/run.md` |
| `f52c056551bbbeea867c69ede47fda4e3acfb3c371c442e97d92f3e4a6762b60` | `openspec/changes/chg-2026-001-macos-m0a/evidence/runs/TASK-M0A-004/run.md` |
| `07346ebc35cbdd415fa55783ad01bcde5378d9c4febf6e92d6575317c6ab4793` | `openspec/changes/chg-2026-001-macos-m0a/evidence/runs/TASK-M0A-005/run.md` |
| `9d6f366cf8af807909ecfc67e44b2f03efcc9487398d6f612bb78e1e43eb36f8` | `openspec/changes/chg-2026-001-macos-m0a/evidence/runs/TASK-M0A-005A/run.md` |
| `fb15d5685452580407896a909d52e695b8c8067911c0dd8b583814ae6ee12d57` | `openspec/changes/chg-2026-001-macos-m0a/evidence/runs/TASK-M0A-005A/read-only-hardware-test-plan.md` |

## Ephemeral prototype artifact identity

The TASK-M0A-005A executable remained available during this rollup and was
re-hashed without executing it:

```text
f9478493480c715b7610fa4aafd58e280798e6ebdc82d4d10491ddcdafb8242a  /private/tmp/arkdeck-m0a-005a-derived/Build/Products/Release/ArkDeck.app/Contents/MacOS/ArkDeck
```

The value matches TASK-M0A-005A's recorded executable hash. The `/private/tmp`
path is ephemeral and is not a controlled artifact store; this match is an
integrity cross-check only, not new signing, Gatekeeper, or distribution
evidence.

## Reproduction

From repository root at the source revision, run `shasum -a 256` with the
paths above as individual argv entries. Do not use this index as an approval
mechanism: git history and maintainer review remain the trust root.

TASK-M0A-006 output documents are intentionally not indexed here because this
file indexes the inputs consumed by the rollup. Their final hashes are recorded
in the task run record after generation; the run record itself is protected by
the reviewed git commit and is not self-hashed.
