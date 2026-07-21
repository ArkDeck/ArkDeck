# CHG-2026-024 design — parameterized device-observation registry

> Status:candidate；仅在 change 获维护者批准后成为设计输入，task 仍须独立 readiness。
> Core baseline:CORE-2.1.0（零 Core 变更）

## 0. Hard boundaries

- Registration is capability metadata, not command discovery or production adoption.
- Existing `OPENHARMONY-HDC-READONLY-PROBES@1.0.0` and its consumers remain
  byte-pinned and unchanged.
- Agent/CI runs no installed HDC/device command. Only maintainer-controlled capture may
  establish production provenance.
- Empty, unknown and failure are distinct typed outcomes. Unknown never removes a device.
- No snapshot establishes binding, authorization, channel protection or mutation authority.

## 1. Version and artifact boundary

- Candidate profile:`OPENHARMONY-TOOLS@0.4.0`.
- New registry:`OPENHARMONY-HDC-DEVICE-OBSERVATION-PROBES@1.0.0` at
  `openspec/integrations/openharmony/device-observation-probes.yaml`.
- Candidate lock:`INTEGRATION-PROFILES-0.5.0`.
- Resource pack:
  `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/DeviceObservation/1.0.0/**`.
- Existing registry/profile references remain available as the 0.3.0 adoption boundary; no
  living path may silently make an old consumer accept the new family.

## 2. Closed entry

`deviceObservationSnapshot` is one command entry consumed as a whole:

- exact executable SHA-256/tool version/platform;
- exact argv `list targets -v` only if controlled capture proves the full contract;
- exact endpoint and valid bracketed `serverIdentityGeneration` receipt before/after;
- existing-server-only precondition; absent/ambiguous/substituted server => unavailable and
  command dispatch 0;
- bounded stdout/stderr/exit contract and a registered parameterized row grammar;
- timeout/cancellation may terminate only the owned client observation process and may not
  kill/restart/adopt/reconfigure the server;
- forbidden effects include server lifecycle/adoption, subserver lifecycle, device migration,
  device mutation, binding mutation and destructive effects.

If controlled capture disproves any condition, the entry is registered `unsupported`; task
completion cannot reinterpret a missing input as support.

## 3. Parameterized snapshot semantics

The grammar is fixed from accepted controlled captures, not invented by implementation. It must
bound total bytes, row count, line length, encoding, delimiter, column count/order, allowed
transport/status literals and the identifier field. Dynamic identifier bytes are values inside the
registered grammar, not an arbitrary-output escape hatch.

The parser consumes the complete stdout:

- valid zero-row family => `.observedEmpty`;
- valid one-to-N unique rows => `.observed(Set<DeviceObservationPseudonym>)`;
- malformed/duplicate/mixed/unsupported rows, stderr, nonzero exit, truncation, timeout,
  cancellation or bracket drift => `.unknown(reason)` for the whole snapshot.

No partial row set is emitted. Row order is semantically irrelevant; identical successful sets are
unchanged. Appeared/disappeared diffing is deliberately not part of this integration registration
and remains CHG-2026-022 consumer behavior.

## 4. Identity and privacy

- Raw connect keys/serials may exist only in the owned process capture and parser memory.
- Before leaving the integration adapter, each identifier is transformed with a per-session random
  key using HMAC-SHA-256. Equality is stable only within that session; cross-session correlation is
  not promised.
- Presentation may use `redacted-device-<24 lowercase hex>` derived from the session pseudonym;
  internal equality retains enough digest bytes to avoid using the display truncation as identity.
- Checked-in controlled receipts contain only source hash, byte/row counts, structural literals,
  effect counters and redacted examples. Raw streams and identifiers remain outside the repository.

## 5. Capture and provenance

Maintainer-controlled capture must cover the sequence in `capture-plan.md`, including successful
zero, one and multiple rows, stable repetition and human plug/unplug transitions. Each observation
records exact tool/executable/argv/endpoint, exit/stderr/stdout length/hash and bracketed server
identity. Lifecycle/subserver/device-mutation dispatch counters remain zero.

Fake/adversarial resources verify parser rejection, timeout/cancellation and privacy only. They
never promote the production entry to supported.

## 6. Adoption boundary

TASK-I24-001 publishes integration inputs and a macOS mapping. CHG-2026-022 must later use a
separate readiness PR to pin the merged registry/profile/resource hashes and design its producer
cadence, fan-out and presentation. This change neither implements nor approves that consumer.

## 7. Rejected alternatives

- Reuse `selectedDeviceAuthorizationBinding`:it is single-capture and binding-specific.
- Treat missing/failed output as empty:would manufacture disappearance events.
- Regex any tab-separated row:would convert unknown tool output into authority.
- Persist raw IDs or deterministic unkeyed hashes:would create unnecessary cross-session tracking.
- Add the fifth family to the existing 1.0.0 registry:would break its closed-family and dependent
  hash/conformance pins.
