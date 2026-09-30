# TASK-XPA-005 — the Windows HDC tuple gate (HDC parity, part 1)

Change: CHG-2026-074-shared-rust-runtime-core. This record covers part 1 (H1) of the HDC parity
slice, TASK-XPA-005. The gate it builds reads CHG-2026-078's registry,
`OPENHARMONY-HDC-WINDOWS-PROBES@1.0.0`, which is still a draft whose sample-derived values are
`TBD(sample)`.

Branch `agent/xpa-005-windows-hdc-tuple-gate-20260930`, one commit on `origin/main`.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. The limits of this run:

- No device was contacted, no HDC or board was used, and no `hdc` was run.
- Nothing installed was read or written.
- No system setting was changed.
- Host tests are not Windows acceptance.

## Scope (lead, 2026-09-30)

The lead asked for "the entire HDC path on Windows, up to the tuple gate". When CHG-2026-078's
TBDs are filled, operations must turn on with no further code. There is to be no production
bypass: "the Windows daemon composes an HDC only for a registry entry from CHG-078". The slice
must also "add a test that shows exactly which registry entry would enable the daemon
composition, and that the daemon refuses without it". The slice is delivered in parts, and this
part is the gate itself.

## What

| Where | What |
| --- | --- |
| `arkdeck-provider-hdc/src/windows_registry.rs` | `WindowsHdcTuple` holds a candidate label, the `hdc.exe` SHA-256, the reported version, the exact `hdc -v` stdout bytes and the one loopback endpoint. `WINDOWS_HDC_TUPLES` is **empty**: TASK-WHR-002 fills it from `windows-probes.yaml` once the registry is registered, one entry per registered candidate. `tuple_in` matches only the exact lowercase digest, never a prefix, a case fold or the version text. `malformed` rejects any entry that is not 64 lowercase hex digits, reuses a macOS tool's hash, has `-v` bytes that do not spell its version with one terminator, or uses an endpoint that is not loopback with a port. A test holds every registered entry to these rules. |
| `arkdeck-provider-hdc/src/provider.rs` | `registered_version("windows", sha)` now reads only the Windows table. The macOS arms are unchanged, so a macOS hash still answers nothing on Windows and a Windows hash nothing on macOS. The read-only provider's server lease now uses `registered_endpoint`: 8710 for the published macOS tools, as before, and the tuple's own endpoint on Windows. The Windows endpoint is `TBD(sample)` in CHG-2026-078, so it is not assumed to be 8710. |
| `arkdeck-agentd/src/windows_hdc_gate.rs` | The one place a Windows development root admits an HDC, decided before the root is opened. It requires `ARKDECK_DEVELOPMENT_HDC_SERVER=managed`, because the Windows root runs no fixture HDC. The path must be absolute. The file's bytes are hashed, as the macOS `measured_hdc` does, and the digest must select a registered tuple. An inherited `OHOS_HDC_SERVER_PORT` must be that tuple's port. |
| `arkdeck-agentd/src/windows_lifecycle.rs`, `main.rs` | `ARKDECK_DEVELOPMENT_HDC_PATH` and `_SERVER` leave `NOT_COMPOSED` and go through the gate instead. `start` now reads values rather than presence. A start the gate admits is still refused, naming the tuple's candidate and digest, because the managed server's Windows composition is part 3 of this slice. With today's empty table that branch cannot be reached. |

What the daemon answers, from the environment alone:

| Input | Answer |
| --- | --- |
| no development HDC | as before |
| `…_HDC_SERVER` other than `managed` | `ARKDECK_DEVELOPMENT_HDC_SERVER accepts only managed` (the macOS text) |
| `managed` without a path | `a managed development HDC server needs ARKDECK_DEVELOPMENT_HDC_PATH` (the macOS text) |
| a relative path | `ARKDECK_DEVELOPMENT_HDC_PATH must be an explicit absolute path` (the macOS text) |
| a path without `managed` | `the Windows development root runs no fixture HDC: …` |
| `managed`, digest not registered | `the development HDC <path> (SHA-256 <sha>) is not a registered Windows HDC: OPENHARMONY-HDC-WINDOWS-PROBES (CHG-2026-078) registers no tuple with that digest; nothing was started` |
| `managed`, registered digest, another port | `OHOS_HDC_SERVER_PORT names another endpoint than the registered HDC <candidate>'s <endpoint>; …` |
| `managed`, registered digest | admitted with exactly that entry (then refused until part 3 composes it) |

The standalone private-endpoint foundation (`ARKDECK_HDC_PATH`/`_SHA256`) keeps its composition.
Its provider now asks the Windows table, and so composes nothing today:
`hdc.platformEvidenceUnavailable`.

## Tests

- `windows_hdc_gate::tests::only_the_registry_entry_of_the_executable_s_digest_admits_it`: a table
  holding an entry with the stand-in's digest admits exactly that entry (path, digest,
  `&table[0]`). Three tables are refused with the exact message: one holding another digest, one
  holding the macOS 3.2.0f digest, and the real `WINDOWS_HDC_TUPLES`. This is the test the lead
  asked for: the entry that enables the composition is the one whose `executable_sha256` is the
  executable's digest, and without it the daemon refuses.
- `…every_other_input_is_refused_before_the_executable_is_read`: every environment refusal happens
  before the file is read. These tests point at a path that does not exist.
- `…the_managed_server_runs_on_the_registered_endpoint_only`.
- `windows_registry::tests` (three) and
  `provider::tests::windows_answers_exactly_from_its_registered_tuples`, plus the extended
  macOS-hash test for `registered_endpoint`.
- `tests/windows_hdc_gate_process.rs`, the real daemon:
  - a development root naming a stand-in HDC as its managed server exits non-zero with the exact
    refusal. This holds on the default endpoint and with an inherited port. Stdout is empty, the
    root stays empty, and the stand-in's bytes are unchanged; the stand-in is not an executable,
    so nothing could have run it;
  - the same stand-in as a fixture is refused as a fixture, and the `external` server mode is
    refused with the macOS text;
  - the private-endpoint foundation, configured with the stand-in and its exact digest, answers
    `device.observations` with `rejected` / `hdc.platformEvidenceUnavailable`.

## Left for the next parts

- Part 2: host-store control actions, the HDC lifecycle, the impact source and tool selection on
  Windows, against the managed-HDC and tool-selection oracles.
- Part 3: the agentd `managed_hdc` owner and its restart lifecycle, `runtime.hdc.*` and
  `control-action.*`, composed only behind this gate. This replaces the "admitted but not
  composed" refusal.
- Part 4: Target adopt/availability, device observations, and the remaining lanes.

## Delegated minor decisions, pending the next rulings batch

1. The Windows development root runs **no fixture HDC**. The macOS owner does run an unregistered
   fixture HDC when it is not managed. On Windows, the only HDC admitted is one that a registered
   tuple names, started as its managed server. Scripted HDC proofs run in process
   (`impl HdcDispatch`), never through the daemon. Reason: the lead's "composes an HDC only for a
   registry entry from CHG-078", and no bypass.
2. The Windows endpoint is **per tuple** and is not assumed to be 8710. An inherited
   `OHOS_HDC_SERVER_PORT` that differs from it is refused, not honoured.
3. The tuple table is a Rust constant in `arkdeck-provider-hdc`, as the macOS
   `registered_version` arms are, and not a file read at runtime. TASK-WHR-002 copies each
   registered candidate from `windows-probes.yaml` into it. `malformed` and its test keep any
   entry from reusing a macOS hash or a wildcard endpoint.

## Gates

See the PR description for the gate output of this commit.
