# Spec impact — CHG-2026-074

- **`openspec/specs/**` (nine capability specs)**: zero changes. No Requirement, Scenario, state
  machine, terminal state, default safety policy or schema required field is added, relaxed,
  tightened or renumbered; `core_change_level: none`, no baseline bump. Both platforms implement the
  same Core Requirements and Acceptance Scenarios (POL-PLATFORM-001).
- **`openspec/architecture/core-portability.md`**: the decision text at `:9` ("not a shared
  Swift/Rust/C++ binary ABI in v1"), the strategy value at `:30` and the "Future shared library"
  paragraph at `:34` are superseded by this change. The edit is delivered by the first Windows task
  (`TASK-XPA-002`), which is why that task's Allowed paths include the architecture and platform
  documents; the observable Core semantics do not change.
- **`openspec/platforms/macos/profile.md`, `windows/profile.md`, `linux/profile.md`**: `Core
  strategy` changes from `native-conforming-shared-contract-vector-suite` to
  `shared-rust-runtime-native-ui-shared-contract-vector-suite`; the Windows profile moves to 0.2.0
  with the W0 spike started and the named-pipe, service, credential, process, file-identity and
  device-access adapters described; macOS gains the Rust daemon nested-code and XPC transport
  notes. No profile override or relaxation of Core (POL-PLATFORM-001).
- **`openspec/platforms/PLATFORM-PROFILES.lock.yaml`**: Windows leaves `not_started_platforms`
  when W0 starts; `verified` may only be recorded for the exact OS/arch/build tuples evidenced;
  macOS stays `needsReverification` until GJ-1..5 pass on the pure Rust daemon.
- **`openspec/contracts/**`**: additive only. `runtime-control-plane.schema.json` gains protocol
  2.1.0 methods and per-method typed schemas; `journal-event.schema.json` records generations
  2.0.0–3.0.0 already accepted by Swift; new language-neutral assets under `spec/` (state table,
  registries, UI semantics, bilingual messages) are generated from the Swift oracle and frozen.
- **`Catalog/**`**: zero operation additions, removals or edits; the digest stays
  `508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684` until an unrelated change
  publishes a new operation.
- **Provider IDs and destructive policy**: unchanged (`hdc`, `workspace`, `analyzer`,
  `arkforge`); no new provider, device profile or destructive admission rule.
- **`PRODUCT-LOOP.md`**: text untouched (maintainer-issued). The conflict between §2 (no new
  proposals) and `core-portability.md:30` (architecture change required) is recorded as a one-line
  compatibility note in the proposal; the Golden Journey re-pass rule on runtime replacement is
  requested as a maintainer decision, not asserted.
- **ADR-0005**: the transport-free handler and versioned frame decisions are kept; the MVP stance
  "same user reachable equals authorised" is proposed to be tightened (peer euid, XPC peer
  code-signing requirement, named-pipe SID/elevation check). An amendment note is delivered with
  `TASK-XPA-003` if the maintainer accepts decision 3.
- **ADR-0009**: its open ruling (which code carries decisions 2 and 4 today) must be settled before
  recovery is ported (`TASK-XPA-014`); this change does not settle it.
