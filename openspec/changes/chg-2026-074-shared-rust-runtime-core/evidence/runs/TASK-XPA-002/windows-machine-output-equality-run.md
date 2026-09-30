# TASK-XPA-002 — Windows `doctor`, `operation list` and `device candidates` machine output byte-equal to the macOS fixtures

Change: CHG-2026-074-shared-rust-runtime-core. Windows phase, slice CI2-B (part 3 of the
remaining XPA-004/XPA-002 work). Base: protected `main` `86d2f2b8` (#2398). Host: the Windows 11
x64 reference host, non-elevated. No device was contacted, no `hdc` ran, and no Windows HDC tuple
was registered or assumed. Host tests are not Windows acceptance.

## The deliverable

TASK-XPA-002 lists: "Windows `doctor`, `operation list`, `device candidates` with machine output
byte-equal to the macOS fixtures". Without the Windows HDC tuple this is achievable for the
read-only foundation with no HDC: the daemon the black-box check starts. That is the state in
which `device candidates` answers `hdc.notConfigured` on every host. The positive `device
candidates` listing a DAYU200 needs the tuple and the board (phase A).

## What the hosts answered

I downloaded (read-only) the three `rust-readonly-recordings-*` artifacts of Swift CI run
36714794680, on `main` `565f8b1d`. In each, `check-readonly.py` recorded the CLI's `--output
json` stdout for the matrix. On Windows that matrix runs through the daemon signed with the
temporary development signer that the parity job creates.

| leaf | macOS | Linux | Windows (signed) |
| --- | ---: | ---: | ---: |
| `doctor` | 2658 B | equal but `observedAt` | equal but `observedAt` |
| `doctor --deep` | 2650 B | equal but `observedAt` | equal but `observedAt` |
| `doctor --require-healthy` | 2849 B | equal but `observedAt` | equal but `observedAt` |
| `operation list` | 10607 B | byte-equal | byte-equal |
| `device candidates` | 369 B | byte-equal | byte-equal |

The one difference is `observedAt`, the doctor report's whole-second UTC time: a wall-clock
value, T2. Every stderr was empty on all three hosts.

## What this change pins

- **Fixtures.** `rust/tests/fixtures/readonly-machine-output/{doctor,deep,healthy,operations,candidates}.cli.jsonl`
  hold the macOS lane's recordings from that run. The one member `"observedAt":"<UTC second>"`
  reads `"observedAt":"<observedAt>"`, exactly once in each doctor answer and nowhere else.
  `provenance.json` names the run, the artifact and the rule.
- **The check.** `check-readonly.py` (`machine_output`) compares the five leaves' stdout on every
  host that runs the full matrix: macOS and Linux over the socket, and Windows through the
  signed daemon. The label is applied first, and then the bytes must equal the fixtures. A
  mismatch fails the lane and names the fixture and the rewrite option.
  - The Windows unsigned refusal recorded before the signed matrix is not what is compared; the
    matrix's own (last) recording is.
  - `check-contracts.py` runs the script from each view's own tree, so a published view compares
    with its own fixtures.
- **Rewriting.** `--write-machine-output` rewrites the fixtures from a run, after a change that
  legitimately moves the output, such as the Catalog. Every host's lane then has to reproduce
  the new bytes. That keeps the three hosts byte-equal wherever the fixture was rewritten, and
  the macOS lane always holds the fixture to its own output.
- **Tests.** `test_contract_checks.py` (`ReadOnlyMachineOutputTests`):
  - the committed fixtures pass with any `observedAt`;
  - a changed availability, a changed reason code, or a non-whole-second `observedAt` fails;
  - the rewrite labels `observedAt`;
  - the unsigned Windows row is skipped.

## Local targeted checks

| command | exit |
| --- | ---: |
| `ARKDECK_DEV_SIGNER_THUMBPRINT=… python rust/scripts/check-readonly.py --bin-dir D:\cargo-target\ci2-xpa002\debug` (signed Windows matrix) | 0, PASS: the Windows output equals the macOS fixtures |
| the same, with `TEMP`/`TMP` set to an 8.3 short path on C: (`…\Temp\AD-SHO~1`) | 0, PASS |
| `PYTHONUTF8=1 python rust/scripts/test_contract_checks.py ReadOnlyMachineOutputTests ReadOnlyImportExpectationTests` | 0 (3 tests) |
| `PYTHONUTF8=1 python rust/scripts/test_contract_checks.py` | 1: 49 tests, 1 failure, `RunDirectoryTests.test_a_passing_run_removes_its_directory_without_a_word`, which asserts a POSIX `0o700` mode and fails on any Windows host, unchanged here (the suite runs on Ubuntu in CI) |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 (0 errors, 0 warnings) |
| `git diff --check` | 0 |

No Rust changed.

Not run here, because the scripts cannot run their Unix path on this host: the macOS and Linux
comparison. They run in the PR's `Rust contract parity` jobs.

## CI

To be recorded by the follow-up.
