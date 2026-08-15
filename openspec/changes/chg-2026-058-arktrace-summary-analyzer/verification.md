# Verification Plan

> Change:CHG-2026-058-arktrace-summary-analyzer@r1
> Status:in-progress（production implementation、contract/fault-injection tests 与 reviewed
> ArkTrace replay evidence 已同车完成；等待本垂直 PR 的维护者 review/merge，Large Trace
> 明确 deferred 且不计入本 change。）

## Environment

- ArkDeck baseline: `60bfa76d6fba3ff1ea9abad031aefa077f5fbbfe` until proposal review;
  implementation evidence must bind its actual protected-main base.
- Core baseline: `CORE-3.0.0`.
- Platform: macOS 14+ arm64.
- ArkTrace: final reviewed Developer ID signed/notarized Phase 5 CLI distribution; product 0.1.0
  build 1; JSON contract 1.0; bundled TraceStreamer identity from its manifest.
- Fixtures: real production CLI self-test trace for availability, bounded synthetic/real trace
  Artifact leases for contract tests, and existing crash-ledger analyzer fixtures for regression.

## Acceptance matrix

| AC ID | Verification method | Expected result | Evidence |
| --- | --- | --- | --- |
| ATI-AC-1 | Compare existing descriptor blob/hash; run catalog generator and exact operation-set tests | `analyzer.summarize-trace@1` is unchanged and no duplicate summary operation exists | contract run |
| ATI-AC-2 | Valid distribution plus not-found/version/contract/hash/parser/manifest/symlink/doctor fault injection | only the exact compatible profile is available; failures occur before running Job creation | contract + platform run |
| ATI-AC-3 | Register crash/hilog/trace in normal and reversed order; inject duplicate/unknown refs and wrong SHA | each closed action resolves one exact binary independent of order; invalid mapping refuses | contract run |
| ATI-AC-4 | Golden `TypedProcessPlan` with source paths containing spaces, quotes, leading dash and Unicode | fixed reviewed arguments plus one path token; no shell/PATH/App | contract run |
| ATI-AC-5 | Mutate/replace source bytes after lease resolution; spy on HDC, capability and device-fact ports | drift refuses before child; all device/capability counts remain zero | integration run |
| ATI-AC-6 | Feed valid production summary and schema/tool/command/trace/parser/provenance/malformed/truncated/oversize negatives | exactly valid ArkTrace 1.0 summary succeeds; every mismatch has stable failure | contract run |
| ATI-AC-7 | Publish, restart daemon/store, reload derived Artifact and compare source/result/tool/parser hashes and bytes | `trace-summary.json` equals validated bytes and complete lineage survives without paths | integration run |
| ATI-AC-8 | Timeout/cancel/crash windows, profile upgrade/rollback/drift, full existing analyzer suite | no guessed replay/fallback; retained exact rollback works; crash/hilog are unchanged | fault-injection + regression run |

## Negative and recovery tests

- Duplicate profile ref, profile-order changes and provider-level resolver fallback.
- Distribution root/ancestor/leaf symlink, missing file, non-regular file, byte/hash/mode/manifest/
  contract/parser/signing identity drift.
- Doctor nonzero, timeout, cancellation, malformed/mismatched output and identity change after cache.
- Artifact lease target/hash/size/path race and child identity race.
- Empty, text, malformed JSON, unknown schema, wrong command/result/tool/trace/parser, missing
  provenance, output truncation and output-budget boundary.
- Crash before spawn, during child, after validation and before/after Artifact publication.
- Daemon restart with prior Job, active upgrade and retained rollback; no blind child replay.
- Privacy scan for source/cache/distribution/executable paths and environment strings.

## Deviations

- No simulation/fake can prove Developer ID/notarization or real ArkTrace compatibility. That
  evidence must come from the exact final distribution named by the production profile.
- Independent >500 MiB Large Trace evidence is explicitly deferred in ArkTrace and is not an
  acceptance condition or claimed result of this summary integration change.
- The deep analysis operation is out of scope. Its absence cannot be hidden by adding arguments to
  the existing summary operation.

## Result gate

- [ ] ArkDeck maintainer reviewed the change/profile boundary together with the production
  implementation in the same vertical GJ-5 PR.
- [ ] All ATI-AC-1 through ATI-AC-8 passed with reviewable evidence.
- [ ] Existing analyzer operation descriptor and crash/hilog behavior stayed compatible.
- [ ] Production profile binds the exact final ArkTrace distribution manifest.
- [ ] Simulation/fake was not counted as signed platform or real Artifact evidence.
- [ ] Traceability and task status were updated in the same vertical implementation PR.
