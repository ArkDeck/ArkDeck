# Change Design

## Contract

`analyzer.analyze-trace@1` 使用现有 analyzer provider 与 ArkTrace distribution generation。

```text
immutable sourceArtifactRef
  + kind (closed)
  + timestampNs XOR [startNs,endNs)
  + optional stable identity filters
  + timeout/maxRows/maxEvents/maxOutputBytes
              │
              ▼
submit-time cross-field validation
              │
              ▼
ArkTrace pinned profile / descriptor-bound source lease
              │
              ├─ kind=context → `context --timestamp-ns ... --window-ms 50`
              │                  or `context --start-ns ... --end-ns ...`
              └─ analysis kind → `analyze --kind ... --start-ns ... --end-ns ...`
                                  (`timestampNs` normalizes to a bounded 100 ms range)
              │
              ▼
closed ArkTrace JSON 1.0 validator
              │
              ▼
exact stdout → trace-analysis.json + source/tool/parser/request lineage
```

## Typed inputs

- `sourceArtifactRef`: required Artifact lease；
- `kind`: `context|cpu|scheduling|slices|range|hot-intervals`；
- time: either `timestampNs` or both `startNs/endNs`；
- filters: `processKey|pid` and `threadKey|tid`；
- limits: required `timeoutMs` 100...120000, `maxRows/maxEvents` 1...100000,
  `maxOutputBytes` 1024...67108864；
- optional `thresholdNs >= 0` and `limit` 1...1000。`thresholdNs`/`limit` are rejected for
  `context`; `limit <= min(1000,maxRows,maxEvents)` for analysis。

Timestamp analysis uses `[max(0,timestampNs-50ms), timestampNs+50ms)` and rejects overflow or an
empty normalized range. Context keeps the timestamp shape and the fixed symmetric 50 ms-per-side
(100 ms total) window.
No omitted limit is inferred from ambient state: optional `limit` defaults deterministically to
`min(1000,maxRows,maxEvents)` and `thresholdNs` to zero inside the Provider.

## Profile and durable identity

The CHG-2026-058 loader returns two closed profiles from one reverified private distribution
generation: `trace-summary@1` and `trace-analysis@1`. They share exact executable/resources/tree
pins but own different fixed operation contracts. Resolver selection remains action-specific;
profile order cannot select bytes. The additive analysis request is persisted as typed fields in
`AnalyzerInvocation`; recovery identity remains path-free and includes a canonical request digest
so a restart cannot reconcile a different analysis as the original action.

## Result validation

Validation first applies duplicate-key and exact numeric decoding, then requires the common
machine success envelope and exact request/limit echo. Tool, source trace and parser provenance
must equal the profile and lease. `context` requires the closed context result and shared global
directory/event limits; `analyze` requires the closed deterministic batch, per-section count
agreement and shared global returned-row limit. All decoded strings pass the existing bounded
host-path scanner. Error envelopes, stderr, truncation, unknown keys and partial JSON fail.

## Publication and failure

`RuntimeArtifactService` treats `trace-analysis@1` like `trace-summary@1`: exact validated bytes
are durably published before the succeeded step outcome. Metadata records source/derived hashes,
request kind/time/filters/limits, tool/parser identity and generated time without physical paths.
Cancellation, timeout, source drift, profile drift or publication failure produce no derived
Artifact and retain existing read-only recovery semantics.

## Compatibility

No byte in `analyzer.summarize-trace.v1.json` changes. Existing summary invocation fields remain
decodable. New optional Codable fields default to nil for old durable actions. Crash/hilog profiles
and generic analyzer validation are untouched.
