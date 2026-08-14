---
id: CHG-2026-058-arktrace-summary-analyzer
revision: 1
status: proposed
class: integration
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos]
---

# 用 pinned ArkTrace CLI 实现现有 Trace summary analyzer

> **恰四类声明**：本 change 不新增 operation 或 provider，但新增 ArkTrace CLI 的
> production integration profile，并改变 analyzer provider 的 production composition。
> 这属于 `AGENTS.md` 明列必须经 OpenSpec + 维护者 PR review/merge 的“新
> integration/device profile”。本 proposed change、`TASK-ATI-001` 的生产实现、测试与
> evidence 必须作为同一个 GJ-5 垂直 PR 接受维护者 review；不得先合入 proposal/readiness
> 载体，也不得把 change 文档的存在当成独立批准。

## §19 治理循环四问

1. **对应的真实安全风险**：当前 `analyzer.summarize-trace@1` 已公开，但生产 daemon
   没有 Trace analyzer profile。若直接复用 `ARKDECK_ANALYZER_PATH` 或让请求提供 path/argv，
   caller 可把任意 executable 冒充 analyzer；若只检查“stdout 是 JSON”，则错误 trace、
   错 command、缺失 tool/parser provenance 或路径泄漏都可被发布为可信 derived Artifact。
   这命中 `PRODUCT-LOOP.md` §3-7/8/9 与 `POL-WORKFLOW-001`、
   `POL-ARTIFACT-001`、`POL-PRIVACY-001`。
2. **为什么不能直接修 Runtime**：这不是既有 profile 的缺陷修复，而是新增 ArkTrace
   distribution/profile 与跨仓版本边界；`AGENTS.md` 要求 change 与对应 GJ-5 产品实现
   同车接受维护者 review。实现仍落在 AnalyzerProvider、dispatcher、daemon composition、
   Artifact service 与 contract tests，不新增治理框架。
3. **推进哪个 Golden Journey**：GJ-5。ArkDeck 已能 capture immutable Trace Artifact，
   但 `analyzer.summarize-trace@1` 在生产上仍 unavailable，无法形成
   `Trace Artifact → structured derived analysis Artifact`。
4. **为什么不会产生治理连锁**：本 change 只登记一个垂直任务；实现、测试、最小文档与
   runtime evidence 同车，不创建 readiness-only、status-only、verified-only 或 archive-only
   PR。参数化 deep analysis 不在本 change 内偷渡，未来若需要必须作为独立 published
   typed operation 重新 review。

## Audit baseline（2026-08-14）

本 revision 重新审计 ArkDeck protected-main candidate
`60bfa76d6fba3ff1ea9abad031aefa077f5fbbfe`。它取代此前短暂审计过的
`2849c5c188717ac351f9228a9cd60c054035fbcf`；后者不再作为实现 pin。

| Current fact | Git blob at baseline | SHA-256 |
| --- | --- | --- |
| `Catalog/operations/analyzer.summarize-trace.v1.json` | `bd466c1c030ce22b13ce87eea5ec6a65a2feaeeb` | `b41b4c43d8d44a88d43dd5da1d87e5297d00dfa4fc22cbb8187fcd64fcdc5e31` |
| `AnalyzerProvider.swift` | `482da2773a9a0c298411c67761eaf4f18bd20260` | `5923d12ebe67eeda193c7f13a529813ce2de9e74d7c034d9ed2729e0668bafe8` |
| `ArkDeckAgentDaemonMain/main.swift` | `ef72e6cf52dc75a9a2cb0c641454506aff7f67cd` | `ef7a48751642f11b14e9b8b5b94aa0a773a1abb42f4c97aaa3a939f517913619` |
| `RuntimeArtifactService.swift` | `2e0f4c03cb9d0fddccee0d9fb187a8a339f8e7f3` | `f86a6e293a7d2dcbd6c644879ccde0b43c83b452b5e8637d78b23a45201e62bb` |
| `RuntimeJobEngine.swift` | `b10031e015f245e2ff37a40b5f299672c39e3f48` | `c695d805c3f7b6d6773a7713e0f6423a6e876c2b631d1a904b6be97a6cff0757` |
| `DescriptorBoundProcessDispatcher.swift` | `cea0f7b03e7e158c56f9c57303acae81cbb27059` | `f879447b6b393b7549a8d72f8995c69ebcd058a0c04ec63fb53962e7c5a78742` |
| `DeviceProviderContract.swift` | `e667a7d873207cf715bd0d32e6516478ca7cd7d9` | `8bbec49aff24b3cda6ce9a3b9cf8ea37b4b759b29422edbcfe41dbb023bf0d42` |
| `openspec/specs/trace/spec.md` | `a8cd0d4f03b964964d1aa7d7036b9029405e9a72` | `813e3e44e791ef05c4090114453f0e35e46e5be4804ea89b458dac00c2490b0c` |

Cross-repository design input is ArkTrace
`cddcd508757db3ebc0f3c7fcad4458076ed07c57` plus its current Phase 5 distribution
contract. The implementation SHALL pin the final reviewed
`distribution-manifest.json`, not this mutable source checkout. Current reviewed input hashes are:

- `scripts/verify_phase5_cli_distribution.py`:
  `e7a0c7a9bf9cd887a27307ecbf4c924ddf7a7b7b381f468330a4de2f6ae266b3`;
- `docs/CLI_DISTRIBUTION.md`:
  `341a5697b3eed0cefeb34f81504e5b0f570011673f0b6739305e9397df6f197f`;
- `docs/SPECIFICATION.md`:
  `803d5d4a06dad57a975eed03a790f11f4f793589fae31add2f28fcf345d2f3ad`.

## Why

`analyzer.summarize-trace@1` is already a published, host-only, binding-free operation
whose sole input is an immutable Artifact lease and whose declared output is
`trace-summary.json`. Reusing it is mandatory; a second summarize operation would split
one product contract into competing names.

The current production path is nevertheless incomplete:

1. daemon composition only creates the crash-ledger profile from
   `ARKDECK_ANALYZER_PATH`; Trace summary is always `analyzer.profileUnavailable`;
2. `AnalyzerExecutableResolver` inherits the provider-level resolver and constructs its
   table from `profiles.first`, so unrelated crash and Trace analyzers cannot safely use
   different pinned binaries;
3. availability hashes only one executable path; it does not bind the signed ArkTrace
   distribution manifest, JSON contract, bundled parser identity or `doctor --self-test`;
4. Trace summary verification accepts any non-empty JSON. It does not bind schema/tool/
   command/trace hash/parser provenance to the invocation;
5. generic Artifact publication synthesizes a wrapper from receipt summary strings instead
   of persisting the exact validated ArkTrace machine result bytes.

The operation is therefore honestly unavailable today. This change specifies the smallest
production integration that makes the existing operation real without granting ArkTrace any
device authority.

## What changes

### In scope

- add a closed, owner-configured ArkTrace summary integration profile derived only from a
  reviewed, signed/notarized `distribution-manifest.json`;
- select executable identity by closed `AnalyzerInvocation.analyzerRef`, not provider ID,
  array order, caller input, PATH or environment-selected argv;
- keep crash/hilog profiles independent and preserve their existing behavior;
- make availability operation-specific and verify manifest/layout/tool/parser/JSON contract,
  followed by bounded `doctor --self-test --json`, before submission;
- lower only fixed `summary --json` arguments and reviewed limits, appending the already
  resolved Artifact path as one argv token;
- validate the complete ArkTrace JSON 1.0 summary envelope, including source trace SHA,
  tool identity, command/result kind, limits and parser provenance;
- publish the exact validated deterministic bytes as `trace-summary.json`, with Runtime
  Artifact metadata binding source/tool/parser/request/derived hashes and byte counts;
- define versioned-directory upgrade and exact-descriptor rollback. Drift makes a profile
  unavailable; Runtime never repairs or guesses bytes.

### Out of scope

- no new summary operation and no changes to
  `Catalog/operations/analyzer.summarize-trace.v1.json`;
- no timestamp/range/PID/TID/context parameters on the summary operation;
- no deep analysis operation. A future `analyzer.analyze-trace@1` (final name subject to
  review) needs its own typed Catalog contract and maintenance approval;
- no ArkTrace GUI/App launch, shell, PATH lookup, HDC route, network capability or
  RuntimeCapability;
- no change to Trace capture semantics, raw Artifact bytes, Core baseline or existing
  crash/hilog analyzer output schema.

## Scope

- Change-local Requirements: `ATI-REQ-001` through `ATI-REQ-005`.
- Change-local Acceptance: `ATI-AC-1` through `ATI-AC-8`.
- Existing operation: `analyzer.summarize-trace@1` (identity and public schema unchanged).
- Contracts/schemas: new versioned ArkTrace distribution/profile reader and ArkTrace JSON
  1.0 result validator; no current living-spec or Catalog delta.
- Core baseline bump: no.

## Requirements

### ATI-REQ-001 — Existing operation ownership

The integration SHALL reuse `analyzer.summarize-trace@1` unchanged. Summary and parameterized
deep analysis SHALL remain separate typed contracts.

### ATI-REQ-002 — Closed executable identity

The production profile SHALL bind a reviewed distribution manifest, absolute versioned install
root, executable/parser identities, JSON contract and fixed arguments. Runtime selection SHALL
use the closed analyzer action; caller input, PATH, profile order and arbitrary argv SHALL NOT
select executable bytes.

### ATI-REQ-003 — Availability before admission

ArkDeck SHALL validate the operation-specific profile and bounded doctor self-test before
creating a running Job. Missing, incompatible or drifted tool/parser/manifest bytes SHALL produce
a stable unavailable reason and zero dispatch.

### ATI-REQ-004 — Immutable lease and exact result

Immediately before execution, Runtime SHALL revalidate the resolved immutable lease. After
execution, it SHALL reject empty, malformed, truncated, oversized, mismatched or incomplete
ArkTrace output and publish only exact validated deterministic bytes with complete provenance.

### ATI-REQ-005 — Host-only lifecycle

The integration SHALL remain `hostOnly`/`binding:none`, use the existing durable process and
Artifact lifecycle, honor cancellation/timeout/restart, leak no host path, and make zero HDC or
RuntimeCapability calls.

## Acceptance

- **ATI-AC-1**: Catalog generation and tests prove that exactly the existing
  `analyzer.summarize-trace@1` owns summary; its descriptor bytes do not change.
- **ATI-AC-2**: valid signed distribution/profile is available; missing, wrong-version,
  wrong-contract, symlinked, wrong-hash, wrong-parser and failed-doctor profiles are unavailable
  before Job admission.
- **ATI-AC-3**: crash, hilog and trace actions resolve their own exact pinned executable;
  reversed profile order yields the same mapping and unknown refs fail closed.
- **ATI-AC-4**: Trace lowering emits an exact argv array with fixed summary/JSON/limits and one
  Artifact path token, including paths containing spaces or punctuation; no shell/PATH/GUI route
  exists.
- **ATI-AC-5**: lease byte/hash drift is rejected immediately before dispatch; trace analysis
  makes zero HDC/device/capability calls.
- **ATI-AC-6**: valid ArkTrace JSON 1.0 summary is accepted; schema/tool/command/trace hash/parser
  provenance mismatch, malformed, empty, truncated and over-budget output are all rejected.
- **ATI-AC-7**: persisted `trace-summary.json` bytes/hash equal the validated result; source,
  request, limits, tool and parser lineage survive daemon restart without path disclosure.
- **ATI-AC-8**: timeout/cancellation/restart and upgrade/rollback fail closed, while all existing
  crash/hilog analyzer contracts remain byte- and behavior-compatible.

## Safety, privacy, and compatibility

- **Failure mode**: uncertainty is unavailable/failed, never fallback to another profile.
- **Privacy**: machine output and durable records identify Artifacts and hashes, not source,
  cache, distribution or executable paths. Child environment remains a closed allowlist.
- **Compatibility**: existing operation input/output declarations and crash/hilog behavior remain
  unchanged. A host with no installed ArkTrace descriptor sees the same honest unavailable state.
- **Platform impact**: macOS arm64 is the only implemented profile. Windows/Linux remain
  deferred and gain no support claim.
- **Rollback**: atomically select a retained, fully reverified versioned descriptor; never mutate
  an active install in place.
