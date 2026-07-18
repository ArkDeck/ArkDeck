---
id: CHG-2026-003-dayu200-image-characterization
status: verified
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
- 正式批准:2026-07-18 由 approval-only commit(先例 #14/#40)将本 change 置为
  `approved`;批准由维护者 review/merge 构成(V2 git-native 治理;approval commit
  实际经 PR #44 squash 合入 main `6c1ba7b`,手工堆叠 PR #45/#46 因重复关闭)。本批准
  不产生任务执行 evidence,也不改变任何 Core、contract、conformance 或 release 状态。

## Verification closure

`TASK-DAYU200-CHAR-001` 的实现(scanner/schemas/fixtures/tests)与全部 evidence
(四个 JSON、summary.md、run.md)由维护者 `lvye` 于 2026-07-18 11:40(Asia/Shanghai)
merge PR #44 合入受保护 `main`,merge commit
`6c1ba7b1d8856143fa673ec9e73010aa3e658de9`;任务 `ready→done` 状态由独立 status
PR #47 于同日 11:48 合入,merge commit
`02f42580f003d00a36f9cef7523c74ab26eda2f7`。三个 change-local AC
(`TEST-CHAR-M0-DAYU200-IMAGE-001`、`TEST-CHAR-M0-DAYU200-CLASSIFICATION-001`、
`TEST-CHAR-M0-DAYU200-NODISPATCH-001`)在
`evidence/runs/TASK-DAYU200-CHAR-001/run.md` 二值 passed。

该 review/merge 构成 `verification.md` acceptance matrix 所要求的维护者
verification confirmation。本文件的 `status: verified` 仅在包含本状态变更的
verification closure PR 经维护者 review 并合入 `main` 后生效;verified 不改变
evidence 的固定边界——分类结论仍为 fixedArchiveOnly、非权威,不构成 DEC-001/
DEC-002 结论、M0B、硬件支持或任何 platform conformance/release claim。archive
仍必须由后续独立 archive PR 完成(先例 #21)。
