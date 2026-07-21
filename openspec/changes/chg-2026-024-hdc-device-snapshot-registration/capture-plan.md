# CHG-2026-024 controlled capture plan

> Status:plan-only candidate. Human maintainer execution only after change approval and a
> dedicated capture review. Agent/CI must not execute this plan or access a real device.

## Goal

Determine whether exact HDC 3.2.0d `list targets -v` on macOS can support a parameterized,
existing-server-only, zero-to-many device-observation family without server lifecycle, subserver,
device-mutation or destructive effects.

## Fixed context recorded for every observation

- human operator and UTC timestamp;
- macOS build, absolute selected executable path, reported version, full executable SHA-256;
- exact endpoint and child-only environment keys;
- argv as an array: `["list", "targets", "-v"]`;
- valid pre/post `serverIdentityGeneration` receipt:PID/start identity, executable identity and
  exact listener endpoint;
- exit code, stdout/stderr byte count and SHA-256, elapsed time and cancellation disposition;
- serverStart/serverStop/serverRestart/serverAdoption/subserverLifecycle/deviceMigration/
  deviceMutation/destructive counters.

The existing server must already be present. If it is absent, ambiguous, substituted or changes
during an observation, do not run/continue the family and record unavailable.

## Required sequence

| Step | Human-controlled state | Required observation |
| --- | --- | --- |
| C0 | zero target devices attached | successful zero-row candidate; otherwise family cannot claim observedEmpty |
| C1 | attach first supported device | one complete connected row |
| C2 | no physical change | byte/semantic repeat yielding the same one-device set |
| C3 | attach a second supported device | complete two-or-more row output proving parameterization and row boundaries |
| C4 | detach one device | successful remaining-device snapshot |
| C5 | detach final device | successful zero-row snapshot matching C0 semantics |

Repeat the sequence sufficiently to show row order does not encode identity semantics. Do not run
device-targeted commands, change authorization/binding, mutate device state, or stop/restart the
server. Physical plug/unplug is performed only by the human operator.

## Repository-safe provenance

- Raw stdout/stderr and raw device identifiers stay in an operator-controlled location outside
  the repository.
- Checked-in receipts contain source hashes, sizes, row counts, fixed non-sensitive literals,
  redacted structural examples, bracketed server receipt and zero effect counters.
- No raw connect key/serial/user path/private key/secret may enter a commit, issue, PR comment,
  test fixture or log.
- Maintainer review/merge of each provenance record is the acceptance act; file existence or an
  Agent-authored summary is not approval.

## Stop conditions

- invocation starts/restarts/reconfigures the HDC server or changes its identity;
- any non-read-only or device-mutation effect is observed or uncertain;
- zero devices cannot be distinguished from failure/unknown;
- multi-row boundaries or dynamic fields cannot be expressed as a closed bounded grammar;
- privacy cannot be preserved without retaining raw identifiers;
- executable/tool/endpoint context drifts.

Any stop condition leaves TASK-I24-001 blocked and the candidate entry unsupported until a new
reviewed revision supplies a safe alternative.
