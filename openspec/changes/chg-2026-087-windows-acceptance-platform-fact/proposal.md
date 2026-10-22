---
id: CHG-2026-087
revision: 1
status: proposed
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-3.0.0
platforms: [windows, linux]
---

# Correct the constitution example of platforms whose implementation has not started

## Why

`POL-PLATFORM-002` still names Windows and Linux together as platforms whose
implementation has not started. The Windows 11 x64 WinUI client in `windows/`
is under active development and is in acceptance. Linux still has no desktop
client. Leaving Windows in that example records a false platform fact in the
constitution.

## What changes

- In scope: replace the `POL-PLATFORM-002` example. Linux remains the example
  of a platform whose implementation has not started and stays `deferred`.
  Windows is named as implementation started and in acceptance, with
  conformance still `notStarted`. The no-support-claim and no-release rule
  stays in force until that platform is `verified`. Constitution document
  version moves from 2.0.0 to 2.0.1 (PATCH: a clarification that does not
  change product pass/fail).
- Out of scope: `PLATFORM-PROFILES.lock.yaml` conformance statuses,
  `not_started_platforms`, Windows/Linux profiles, conformance cases, support
  cells, releases, and any claim that Windows is `verified` or `supported`.
  Every required Windows 11 case remains `NOT_RUN`. Compilation and hosted CI
  do not advance conformance.
- Observable product behavior is unchanged. The constitution text no longer
  says Windows implementation has not started.

## Scope(涉及的 Requirement/AC)

- Requirements: `POL-PLATFORM-002` example and the unchanged `deferred` rule
- Acceptance: WAP-AC-01, WAP-AC-02
- Contracts/schemas: none
- 是否需要 Core baseline bump: no

## Safety, privacy, and compatibility

- Failure modes: treating this clarification as Windows support, release, or
  conformance passage. This change forbids that reading.
- Data/schema compatibility: none
- 平台影响: macOS stays the only current delivery platform and needs no
  reverification. Linux stays not started and `deferred`. Windows acceptance
  work does not waive Core AC and does not authorize a support claim or release.
- Rollback/migration: restore `POL-PLATFORM-002` and constitution version 2.0.0.
  No data migration.
