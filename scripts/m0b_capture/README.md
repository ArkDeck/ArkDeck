# M0B DAYU200 bring-up capture runbook

CHG-2026-006 / TASK-M0B-001. **Human-operated.** The Agent drafted this runbook
and `capture.py`; a human maintainer executes them against the physical DAYU200.
The Agent never runs real `hdc`.

This run produces first `observed`-level real-device facts: discovery,
authorization workflow, toolchain/build facts, controlled raw capture, and a
read-only `hidumper` probe for the ui-dump wrapper. It is **not** a flash, does
**not** write device state, and makes **no** support or compatibility claim.

## Before you start

- Physical DAYU200 (RK3568) connected over **USB**; you have a maintainer time
  window and can confirm the physical target.
- `hdc` available (DevEco/SDK). Note its absolute path.
- Pick a **controlled output directory OUTSIDE any git repository**, e.g.
  `~/m0b-capture/2026-07-xx/`. `capture.py` refuses to write inside a repo, so
  serial-bearing bytes never land in the ArkDeck tree.

## Hard safety rules (enforced by `capture.py`, restated for you)

1. **Read-only allowlist only.** `capture.py` can run only these fixed commands;
   it accepts no free-form command string:

   | id | command | purpose |
   | --- | --- | --- |
   | `hdc-version-flag` | `hdc -v` | client version |
   | `hdc-version-word` | `hdc version` | client version |
   | `hdc-checkserver` | `hdc checkserver` | server/daemon version |
   | `hdc-list-targets` | `hdc list targets` | discovery |
   | `hdc-list-targets-verbose` | `hdc list targets -v` | discovery detail |
   | `hidumper-help` | `hdc [-t KEY] shell hidumper --help` | ui-dump wrapper facts |
   | `hidumper-services` | `hdc [-t KEY] shell hidumper -ls` | ui-dump wrapper facts |

   This table mirrors `COMMAND_SPECS` in `capture.py` (the authoritative
   definition); `test_capture.py` asserts the two stay in sync.

2. **Do not run anything else by hand.** No `install`/`uninstall`, no
   `file send/recv`, no `reboot`/`boot`, no `tmode`/`tconn`, no
   `kill`/`start`/`kill -r`/`start -r`/`killall-sub`, no flash/fastboot/vendor
   tool. `GAP-DAYU200-RECOVERY-PATH` is still unknown — nothing that could brick
   or drift device state.
3. **The only device-state change is the on-device trust confirmation** during
   authorization (you tap "allow/trust" on the device screen). That is expected
   and revocable; it is not done by the script.
4. **Serial-bearing bytes stay in the controlled directory.** The repo only ever
   receives hashes and the redacted manifest. Do not paste raw capture bytes
   into the repo.
5. The capture also implicitly starts a local hdc host server; leave it running
   (external ownership) — do not kill it. `capture.py` stops draining a
   command's pipes ~2 s after the client exits, so the auto-started server
   holding the inherited pipe ends cannot stall or distort a capture.

## Steps

1. **Sanity-check the harness (no device needed):**
   ```
   python3 scripts/m0b_capture/test_capture.py
   ```
   Expect all tests OK. These never touch real `hdc`.

2. **Discovery + toolchain, before authorization.** With the device plugged in
   but not yet trusted:
   ```
   python3 scripts/m0b_capture/capture.py \
     --hdc /absolute/path/to/hdc \
     --out-dir ~/m0b-capture/2026-07-xx/pre-auth \
     --commands hdc-version-flag,hdc-version-word,hdc-checkserver,hdc-list-targets,hdc-list-targets-verbose
   ```
   The first command may auto-start the hdc host server; that is expected.
   Record what `list targets` shows in the **unauthorized** state (often
   `[Empty]` or an unauthorized marker). This is the AUTH-001 "before" state.

3. **Authorize on the device.** Trigger the trust prompt on the DAYU200 screen
   and confirm trust there. If a prompt does not appear, note how you triggered
   re-enumeration (replug) — do **not** kill the server to force a popup.

4. **Discovery again, after authorization.** Fresh output directory:
   ```
   python3 scripts/m0b_capture/capture.py \
     --hdc /absolute/path/to/hdc \
     --out-dir ~/m0b-capture/2026-07-xx/post-auth \
     --commands hdc-list-targets,hdc-list-targets-verbose
   ```
   The target should now be ready. Note the connectkey shown (this is the device
   identity; keep it only in the controlled directory).

5. **Negative authorization path (best effort).** Observe at least one
   denied/timeout path — e.g. decline/ignore the trust prompt on a fresh
   enumeration, capture `list targets` — or, if you cannot reproduce it,
   truthfully record why in the run notes.

6. **hidumper read-only probe.** With the device authorized, supply the
   connectkey via `--target` (only inserted in the fixed `-t` slot; masked in the
   redacted manifest):
   ```
   python3 scripts/m0b_capture/capture.py \
     --hdc /absolute/path/to/hdc \
     --out-dir ~/m0b-capture/2026-07-xx/hidumper \
     --target <connectkey> \
     --commands hidumper-help,hidumper-services
   ```
   This captures the wrapper facts the later integration change needs to fix the
   HiDumper call wrapper (`ui-dump` spec). Make no compatibility claim here.

## After capture

Each output directory (created `0o700`, files `0o600`) contains, for every
command: `NN-<id>.stdout`, `NN-<id>.stderr` (byte-exact up to a 4 MiB per-stream
retained cap; overflow is recorded in the `truncated` flag), plus
`manifest.json` (full, with real paths/connectkey — controlled location only)
and `redacted-manifest.json` (hashes + counts, home path and connectkey masked,
re-checked by an output-side redaction gate before it is written — safe to
reference from the repo).

Exit codes: `0` capture ok and self-check passed; `1` capture ran but the
self-check failed; `2` usage/harness error (refused location, existing output
file, unexecutable hdc, failed redaction gate — the run is not evidence).

Manifest semantics worth knowing when drafting evidence:

- `exitCode` is the verbatim subprocess return code (negative = killed by that
  signal); it is `null` when the command timed out (`timedOut: true`) — timeout
  is its own channel, never an exit-code value.
- `selfCheck.*.serialPresent` is `null` on runs without `--target` (discovery):
  the connectkey is not yet known there, so **treat discovery-run streams as
  serial-bearing regardless**.
- `evidenceClass` is `controlledHumanCapture`. A `realHardware` classification
  of record can only be made by the human-attested hardware-evidence record,
  never by this tool's manifests.

- Confirm `selfCheckPassed: true` in each manifest. If it is `false`, the output
  contained a user path or key material — investigate before proceeding and do
  not copy those bytes anywhere.
- Hand the maintainer a note of: hdc path/SHA-256/version, macOS build, the
  device build/API you observed **on the device** (not from an image filename),
  the connectkey, and per-command exit codes + SHA-256.
- The Agent then drafts
  `openspec/changes/chg-2026-006-dayu200-m0b-bringup/evidence/runs/TASK-M0B-001/run.md`
  and the `hardware-evidence.schema.json` record (provider `none`) from the
  redacted manifests plus your notes, and the `observed` hardware-matrix row —
  for your review/merge. Raw serial-bearing captures are referenced by hash only
  and stay in your controlled location.

Nothing here promotes the row past `observed`, resolves any `GAP-DAYU200-*`, or
makes a support claim; DEC-002 stays open.
