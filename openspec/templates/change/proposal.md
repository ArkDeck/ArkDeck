---
id: CHG-YYYY-NNN
revision: 1
status: proposed
supersedes_change_id: null # approved predecessor only; approval revokes its claim eligibility after all claims are terminal
supersession_barrier_attestation_id: null # successor preallocates CHGSUPAUTH-*; null when supersedes_change_id is null
class: core | capability | integration | platform | implementation-only
schema: arkdeck-behavior | arkdeck-platform
core_change_level: none | patch | minor | major # arkdeck-behavior is minor/major only in V1
owner: human-owner
core_baseline: CORE-1.0.0
platforms: [shared]
# Required when core_change_level is minor/major:
# platform_revalidation:
#   macos: { disposition: reverifyRequired, owner: owner-id, milestone: Mx }
#   windows: { disposition: deferred, owner: owner-id, milestone: Wx }
#   linux: { disposition: deferred, owner: owner-id, milestone: Lx }
---

# Change title

## Why

说明问题、用户影响和为什么现在需要改变。

## What changes

- In scope
- Out of scope
- Observable behavior before/after

## Impacted specifications

- Requirement IDs
- Acceptance IDs
- Contracts/schemas
- ADR/platform profiles
- 是否需要 Core baseline bump

## Safety, privacy, and compatibility

- Failure modes
- Data/schema compatibility
- macOS impact
- Windows impact
- Linux impact
- Rollback/migration

## Approval

- Human decision：pending
- Approved revision：—
- Notes：—
