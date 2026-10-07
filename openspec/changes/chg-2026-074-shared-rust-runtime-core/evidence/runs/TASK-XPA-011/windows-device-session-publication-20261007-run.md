# Windows Device Session admission chronology and publication retry

A known terminal `debug.hap@1` Job can have fresh evidence at time `t`, followed by RuntimeCapability consumption and its first mutation at `t + 1s`. The Session publisher previously required consumption no later than the evidence timestamp, rejected this valid audit, and left publication unbound. The whole-Job import-reference census then correctly refused the unfinished publication. This change consumes the existing Runtime chronology: fresh evidence precedes consumption, and consumption precedes every recorded mutation or compensation intent. The default read-only chronology and original plan, target, capability correlation, fingerprint, expiry and confirmed-outcome checks remain in force.

For an unchanged, known terminal HAP with its original consumed admission audit and the exact unbound source-integrity failure marker, `job.reconcile` now delegates to the existing publication-only retry. It publishes the retained source and finalized event without resuming the Job, dispatching a device operation, repairing an authority lineage, or rewriting capability records. The absent-admission preconsume path retains its existing proof. Unknown/torn journals, changed provenance, missing audit, consumption at or after its original expiry, late admission and existing proposals remain refusals. Expiry validates the original consumption; publication does not mint a new use. The correction is in shared Rust code; it also applies to macOS builds using this publisher. Catalog, operation contracts and hardware acceptance predicates are unchanged.

The added fixture uses the production admitter and runner with an isolated fake provider, an actual consumed audit, and a deterministic one-second evidence/consumption boundary. It checks succeeded and confirmed-failed publication, the original journal prefix plus exactly one finalized event, unchanged execution/capability/provider bytes, complete import-reference census, and negative authority/replay paths. Its new retry clock stays at the original terminal time; the historical preconsume fixtures retain their original clocks. These are software checks and do not constitute hardware evidence.

## Local targeted checks

Checks use the established `run-cargo.py` owner `signing-readiness`, its fixed external cache, jobs2, the approved development signer only for task-private signed process fixtures, and child environments cleared of live HDC/device/SDK opt-ins. CLI fixture build completed before the direct-consumer process suites. No actual Runtime, credential or device state was edited by this lane.

The commands below ran inside that owner runner. All logs are relative to `tools/logs/windows-device-session-admission-time-20261007/`.

| Cargo command | Actual result | Log |
| --- | --- | --- |
| `clippy --locked --offline -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings` | exit0, 1.599s | `clippy-hoststore-direct-4.log` |
| `build --locked --offline -p arkdeck-cli` | exit0, 13.591s | `build-cli-fixture-3.log` |
| `test --locked --offline -p arkdeck-hoststore -- --test-threads=2` | exit0, 563 passed / 7 ignored, 401.650s; HAP14/14 | `test-hoststore-4.log` |
| `test --locked --offline -p arkdeck-soak -- --test-threads=2` | exit0, 5 passed / 1 ignored, 39.170s | `test-soak-4.log` |
| `test --locked --offline -p arkdeck-agentd -- --test-threads=2` | exit0, 185 passed / 3 ignored, 717.647s | `test-agentd-5.log` |
| `fmt --all --check` | exit1 before rustfmt, Windows command-length error206 | `fmt-all-check-3.log` |
| `fmt -p <each exact workspace member> --check` | all13 members exit0, 13.188s | `fmt-workspace-members-4.log`, `fmt-members-4.json` |

The final suites total753 passed, zero failed and11 ignored. The account fixtures passed without changing their guards or assertions after Root completed a typed normal stop and proved the original account instance exited with its state preserved. The initial combined run stopped at the legitimate already-serving-root guard; the complete agentd rerun also covers all later Windows binaries omitted by that stop. All initial failures are retained under `tools/logs/windows-device-session-admission-time-20261007/`: `test-hap-publication.log` (one malformed fixture decode was incorrectly unwrapped), `test-hap-full-2.log` (a settled failed-HAP repeat was incorrectly expected to bypass its existing lineage refusal), and `test-hoststore-direct-3.log` (two account fixtures refused an already-serving different state root before their listening banner). The account guard was not changed. `fmt-all-check-3.log` retains the Windows command-length error206 before rustfmt; the exact per-workspace-member fallback covers the complete workspace member census.

Final source/document checks passed: `sh scripts/check-sdd.sh` exit0 (`sdd-final-8.log`, 3.366s) and `git diff --check` exit0 (`diff-final-8.log`). The initial bare `sh` launcher was absent from Windows PATH (WinError2 before SDD); the successful check uses the already-installed Git shell with process-local PATH/Python only. No installation or global configuration changed. The exact final file snapshot is rechecked in `sdd-final-9.log` / `diff-final-9.log` and recorded in the CREATE_NEW local source freeze.

## CI

Not yet submitted for this increment. Targeted local checks do not replace the protected-main CI or maintainer review, and no real-device result is claimed.
