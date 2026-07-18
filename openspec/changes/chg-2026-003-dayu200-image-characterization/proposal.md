---
id: CHG-2026-003-dayu200-image-characterization
status: approved
class: implementation-only
core_change_level: none
owner: lvye
core_baseline: CORE-1.0.0
platforms: [macos]
---

# Characterize the DAYU200 image archive offline before M0B

## Why

DAYU200 (RK3568) is the candidate under evaluation for DEC-001 (still open; see
`openspec/planning/open-questions.md`); this change produces the characterization
evidence that informs that decision. Before choosing or
implementing any Flash Provider (DEC-002) or drafting the Route-B CLI capability,
ArkDeck needs plain facts about the fixed vendor image archive: exact member
inventory with hashes, a conservative package-family classification and an
explicit list of unknowns. This is read-only offline research; it cannot satisfy
DEC-002, M0B or any hardware/support claim.

## What changes

### In scope

- A small, shell-free, read-only streaming scanner (`scripts/archive_characterization/`,
  Python 3 stdlib only) that, without extracting
  members to disk or executing anything:
  1. pins the archive identity (byte size + SHA-256, path supplied at claim time);
  2. produces an ordered member inventory (path, size, per-member SHA-256);
  3. rejects dangerous members (absolute paths, traversal, links, devices,
     truncation, size mismatch) with fixed error codes before any classification;
  4. classifies `imagePackageFamily ∈ {rockchipRawImageSet, unknown}` with a
     short, documented, closed decision rule over validated member paths,
     regular-file kinds and sizes only.
- Hazard fixtures for the rejection paths and unit tests for every branch of the
  decision rule (positive and negative).
- Evidence JSONs: archive-identity, member-inventory, package-classification and
  process-audit (with `deviceFlashProvider: unknown`, `targetCompatibility: unknown`,
  `imageProfileReadiness: candidateNonExecutable`), plus a gaps list feeding the
  later Integration change and the Route-B CLI plan-only work.

`unknown` is a valid, expected output. A non-unknown result additionally requires
the fixed raw archive identity, regular-file kinds and non-zero sizes; archive
basename, host locator, payload text, hashes and marketing/model strings are not
classification inputs. The result is fixed-archive-only and non-authoritative.

### Out of scope

- M0B hardware bring-up; satisfying DEC-002; selecting/implementing any Provider.
- Any device, HDC, flashd, USB/UART/TCP or vendor-tool interaction.
- Executing any member or persistently extracting GB-scale images.
- ArkDeck/ArkFlash product code, Image Profile contracts, Integration lock entries.
- Modifying accepted Core requirements/AC/contracts or any lock.

## Impacted specifications

- Core behavior：none · Core baseline update：no
- Platform Profile / Integration lock / hardware matrix：unchanged

## Platform impact and revalidation

| Declared platform | Disposition | Reason |
| --- | --- | --- |
| macOS | no revalidation trigger | host-side offline evidence only |
| Windows | out of scope; lifecycle unchanged | no implementation or support claim |
| Linux | out of scope; lifecycle unchanged | no implementation or support claim |

## Safety, evidence and compatibility

- The vendor archive stays outside the repository; evidence records size/SHA-256
  and inventory hashes, never raw member bytes or a username-bearing locator.
- Hazards in the fixed input stop the Task; synthetic hazard fixtures are
  negative tests only.
- Device/HDC/vendor-tool/network dispatch counters are zero by construction and
  asserted by the audit AC.

## Approval

- 2026-07-14 交互决策接受了六条件分类器、ARC001..ARC009、evidence 边界与单任务范围(结构性决策,非批准)。
- 正式批准:2026-07-18 由 approval-only PR(先例 #14/#40)将本 change 置为
  `approved`;批准由维护者 review/merge 该 PR 构成(V2 git-native 治理)。本批准
  不产生任务执行 evidence,也不改变任何 Core、contract、conformance 或 release 状态。
