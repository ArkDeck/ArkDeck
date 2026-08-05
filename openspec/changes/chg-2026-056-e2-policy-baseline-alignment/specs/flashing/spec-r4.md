# Flashing Specification Delta — r4

> Change: `CHG-2026-056-e2-policy-baseline-alignment` (r4)
> Target: `openspec/specs/flashing/spec.md`
> Baseline: `CORE-3.0.0`
> Proposed baseline: `CORE-4.0.0`

## ADDED Requirements

### Requirement: REQ-FLASH-016 Board profiles are board-scoped; build facts are derived

A published DAYU200 device profile SHALL be selected as a **board**: its partition map, its
write-forbidden partitions, its prerequisites, and the rules that classify an archive member as a
mapped partition image, an orphan image, the loader, the partition table or non-partition
metadata. Every published reference SHALL describe the same board; naming one reference rather
than another SHALL NOT change any board fact.

No admission decision SHALL depend on a firmware build being enumerated in the product. A profile
carries per-build fields, but they SHALL be populated from the archive under authorization before
use, and the compiled-in values SHALL NOT be consulted by any path that admits, plans, stages,
dispatches or verifies a flash.

The facts of a particular build SHALL be derived from the archive under authorization, at import,
and recorded on the resulting Artifact lease:

- the archive's byte count and SHA-256, and each member's name, byte count and SHA-256;
- the partition table, parsed from the archive's own `parameter.txt`;
- the runtime build version, read from the bytes of the system image the plan will write.

The runtime build version SHALL NOT be inferred from the archive's file name or from any build
log inside it. Both state the daily build's label, which is not what the flashed device answers:
the 2026-07-28 daily is named `7.0.0.35` and its `daily_build.log` says `OpenHarmony_7.0.0.35`,
while the value baked into its `system.img` — and therefore the value the booted device reports —
is `OpenHarmony-7.0.0.36`.

An import SHALL fail closed when the archive does not conform to the board profile: a mapped
partition with no member, a partition table that does not parse or that declares a partition the
board does not know, or a system image from which no runtime build version can be read.

Before an upload begins, a declared byte count and digest SHALL be checked for **shape** — a
positive, bounded size and a lowercase 64-character SHA-256 — and SHALL NOT be checked for
membership in any set of known builds. The archive itself is judged on commit, against its bytes.

#### Scenario: A firmware build the product has never seen is importable

- **GIVEN** a DAYU200 images archive for a build no published profile enumerates
- **WHEN** it is imported against the `dayu200` board profile
- **THEN** its member digests, partition table and runtime build version are derived and recorded
  on the lease, and no code change is required to accept it

#### Scenario: A non-conforming archive is refused before any authority exists

- **GIVEN** an archive whose partition table omits a partition the board maps
- **WHEN** it is imported
- **THEN** the import fails closed with the exact missing partition named, and no lease, plan or
  authority is created

### Requirement: REQ-FLASH-017 Byte integrity is carried by the lease, not by product knowledge

The guarantee that a destructive Step writes exactly the confirmed bytes SHALL rest on the
Artifact lease and the exact-plan authority, not on the product having shipped the digest in
advance. Before the first destructive Step the runtime SHALL re-verify that the leased archive's
byte count and SHA-256 still match what the plan was materialized against, and SHALL refuse
otherwise.

Removing per-build enumeration from the device profile SHALL NOT weaken this: the operator
confirms the digest of an exact plan derived from the archive in front of them, and the runtime
re-checks that digest at the last safe boundary. A digest allowlist compiled into the product
protects only builds already listed and refuses every other build outright, which is recognition,
not integrity.

#### Scenario: Drifted bytes are refused at the last safe boundary

- **GIVEN** a confirmed exact plan over an imported archive
- **WHEN** the leased bytes no longer hash to what the plan was materialized against
- **THEN** destructive dispatch is 0 and the Job records the drift

### Requirement: REQ-FLASH-018 Post-flash verification compares against the flashed image

Post-flash verification SHALL compare the device's reported build version against the runtime
build version **derived from the image the plan wrote**, not against a version constant carried
by the device profile.

That version SHALL reach the verification step as a fact the Runtime resolved, alongside the
Artifact lease it resolved it from. Materializing a step SHALL remain a pure function of its
typed inputs and that context: no step materializer may open the image archive. Deriving the
version while materializing would make the plan depend on I/O, and deriving it from the staged
images is not available either — staging is scoped to the flash action and released before
verification runs.

#### Scenario: Verification uses the derived version

- **GIVEN** a completed write plan whose system image declares `OpenHarmony-7.0.0.36`
- **WHEN** post-flash verification reads the device's `const.ohos.fullname`
- **THEN** it passes only if the device answers that same value

#### Scenario: Every published step materializes without reading a file

- **GIVEN** the typed inputs and resolved context of a flash job
- **WHEN** each published step of `flash.dayu200@1` is materialized
- **THEN** every step materializes, and none of them opens the image archive
