# TASK-UD-CAP-MUT-001 — Phase A attempt 2 reflash abort

## Classification

- Window: `2026-07-21T16:02:09+08:00` through
  `2026-07-21T16:37:15+08:00` (repository-facing redacted-manifest file times).
- Change/task: `CHG-2026-008-ui-dump-hidumper-wrapper` /
  `TASK-UD-CAP-MUT-001`.
- Result: **ABORTED / NOT REUSABLE** after sequence 10. This attempt does not
  satisfy `INT-UD-CAPTURE-MUT-001` and does not claim Recipe success,
  compatibility, support, conformance, release status, or canonical
  `AC-DUMP-*` PASS.
- Evidence class: partial `controlledHumanCapture`.
- Claimed operator: human maintainer `fuhanfeng`. Agent installed-HDC/device/
  destructive dispatch count: `0`.

## Repository-safe record

- Harness schema: `arkdeck-ud-capture-redacted-1.1.0`.
- Harness files matched the merged remediation hashes recorded by the separate
  ready-restore PR: README `6e5db182…`, capture `b407aaa0…`, tests
  `b29c15b8…`.
- Eleven redacted manifests (`00`–`10`) and `capture-hashes.md` are preserved in
  this directory. All raw stdout/stderr and full manifests remain only in the
  original operator-controlled repository-external directory.
- No attempt-2 connect key, WinId, local HAP path, raw bytes, full manifest, or
  session-directory name appears in this evidence.

## Command ledger

All eleven recorded harness invocations completed without timeout, truncation,
drain incompleteness, or repository-facing self-check failure; each recorded
process exit `0`.

| Seq | ID | Disposition |
| ---: | --- | --- |
| 00 | `HP-0` | pinned HDC hash/version capture complete |
| 01 | `HP-1` | single USB / Connected target reported by the operator |
| 02 | `FX-1` | install capture complete; schema-1.1 exact HAP-path echo policy PASS |
| 03 | `FX-2` | fixture start capture complete; foreground confirmed by the operator |
| 04 | `HP-2` | target binding unchanged before `INV-1` |
| 05 | `SC-1` | pre-`INV-1` path absent |
| 06 | `INV-1` | inventory capture complete; unique fixture window selected locally |
| 07 | `SC-1` | post-`INV-1` path absent |
| 08 | `HP-2` | target binding unchanged before `R1` |
| 09 | `SC-1` | pre-`R1` path absent |
| 10 | `R1` | capture complete, but its output is not reused or classified by the later successful attempt |

The attempt ended before the mandatory post-`R1` `SC-1`; its sidecar state was
therefore not closed by this runbook attempt.

## Abort trigger and destructive-action record

After sequence 10, the human operator reflashed the same physical DAYU200
outside this runbook. The action occurred after the last attempt-2 redacted
manifest (`2026-07-21T16:37:15+08:00`) and before attempt 3 began at
`2026-07-21T17:09:21+08:00`. The exact flash command, wall-clock instant, image
digest, and flash transcript were not captured by this harness. The operator
subsequently confirmed that the target was the same DAYU200 (RK3568) and that
the post-flash tuple was OpenHarmony `7.0.0.34` / API `26.0.0`.

The reflash was a human destructive action, not an Agent dispatch. It
invalidated the attempt's target/window/fixture/sidecar state. Therefore:

- no post-flash command used this attempt's connect key, WinId or session;
- no attempt-2 Recipe was retried or treated as attempt-3 evidence;
- no `FX-3`/`FX-4` was issued against the invalidated pre-flash state;
- attempt 3 started in a new controlled directory at `HP-0` and repeated every
  physical, target, fixture, window and sidecar gate.

## Dispatch and conclusion

| Item | Count / result |
| --- | --- |
| Human installed-HDC process dispatches | `11` |
| Human external destructive actions | `1` reflash, outside the closed capture harness |
| Agent installed-HDC/device/destructive dispatches | `0 / 0 / 0` |
| `R1` / `R2` / `R3` dispatches | `1 / 0 / 0` |
| Mandatory post-`R1` sidecar inventory | not executed before reflash |
| `INT-UD-CAPTURE-MUT-001` | **NOT PASS / ATTEMPT ABORTED** |

`hardware-evidence.json` is intentionally absent for this attempt. The complete
fresh attempt and its real-hardware record are in sibling directory
`attempt-3-complete-20260721/`. The earlier #219 attempt-1 evidence remains
unchanged and is not reused or rejudged here.
