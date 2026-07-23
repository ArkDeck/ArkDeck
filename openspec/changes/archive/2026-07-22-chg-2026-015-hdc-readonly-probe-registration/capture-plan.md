# CHG-2026-015 authoritative input capture plan

> Status:plan-only (r2). This document fixes what the human maintainer will capture, with which
> instrument, to produce the four authoritative input families that block `TASK-I15-001`. It
> authorizes no new tooling, no registration, and no task execution. An Agent SHALL NOT execute
> installed `hdc` or any host observation on the maintainer's behalf.
>
> Provenance acceptance = the maintainer merges the capture-record evidence PR (the same trust
> root as every merge; precedent: M0B evidence PR #58).

## Instruments (fixed; nothing new)

1. **`scripts/m0b_capture/capture.py` — used AS-IS, unmodified.** Its closed allowlist already
   contains every hdc command this plan needs:`hdc-version-flag`(`-v`)、`hdc-version-word`
   (`version`)、`hdc-checkserver`(`checkserver`)、`hdc-list-targets`(`list targets`)、
   `hdc-list-targets-verbose`(`list targets -v`)。The harness commit OID and file hash are
   recorded in the capture record at execution (M0B precedent:evidence cites capture.py by
   hash). Modifying the allowlist is out of scope for this plan and for CHG-015.
2. **Commandless host observations (`OB-*`) — maintainer-executed, outputs recorded.** These are
   host-local reads with no hdc dispatch, no device access and no argv-payload hazards, so manual
   execution with recorded output is acceptable (unlike UD Phase A, no byte-exact golden or
   parser registration is derived from them; they feed redacted platform receipts). Fixed list:

   | ID | Command shape | Purpose |
   | --- | --- | --- |
   | `OB-1` | `ps -axo pid,ppid,lstart,command` filtered to the hdc server process | server process identity/start identity |
   | `OB-2` | `lsof -nP -iTCP -a -p <server pid>` | exact listener endpoint (merged M0A evidence documents the loopback form `::ffff:127.0.0.1:8710`) |
   | `OB-3` | `shasum -a 256 <hdc executable>` + `stat` | executable identity for the server/client tuple |
   | `OB-4` | `stat` on the user-configured hdc key material paths; public-key fingerprint only (e.g. `ssh-keygen -lf <public key file>` when applicable) | key locator metadata + public fingerprint |

   `OB-4` hard rules:the private key file is **never** read, hashed, copied or fingerprinted;
   only existence/permissions/size/mtime metadata plus a public-key fingerprint are captured.
   Key paths come from the observed hdc configuration on this host, not from a hard-coded
   default (design Decision 2:no default hard-coded path authority). All user paths are
   redacted to placeholders in repo-facing records.

## Family capture matrix

| Family | Capture window | Procedure |
| --- | --- | --- |
| `serverIdentityGeneration` | **host-only, any time** | `OB-1/OB-2/OB-3` → `hdc-checkserver` via harness → `OB-1/OB-2` again. If no server exists beforehand, record the absence, run the command, and record the implicit start event — this is exactly the Decision-3 no-start evidence for the pinned version, honestly captured either way. |
| `selectedDeviceAuthorizationBinding` | **device window** (DAYU200 physically present and confirmed) | `OB-1/OB-2` → `hdc-list-targets` → `hdc-list-targets-verbose` via harness → `OB-1/OB-2` again. Serial stays out of repo docs per M0B redaction conventions; the raw `-v` stream is the family's candidate output evidence. |
| `keyAccessDiagnostics` | **host-only, any time** | `OB-4` only. No hdc command required. |
| `subserverCapability` | **host-only / documentation** | Primary source = authoritative hdc source/documentation for the pinned `Ver: 3.2.0d` verb surface (`spawn-sub`/`killall-sub` presence and semantics) — design Decision 4 explicitly allows authoritative documentation as provenance, and CHG-2026-011 established the hdc-source documentation precedent. No controlled help capture is planned:the harness allowlist has no help id, and this plan does not authorize ad-hoc commands. If registration review later finds documentation insufficient, extending an instrument is a separate maintainer decision. |

Every harness invocation is bracketed by `OB-1`/`OB-2` before and after; a changed server
pid/start-time/endpoint across a bracket is recorded as a generation event, honestly, whatever
the direction. Version facts are cross-checked against the pinned M0B tuple
(hdc SHA-256 `48395ba8…`, `Ver: 3.2.0d`); drift is recorded and stops the capture session.

## Scheduling

- Three of four families need **no device** and can be captured in any host session before the
  device window.
- `selectedDeviceAuthorizationBinding` needs the DAYU200 and must run in its **own window** —
  not inside the UD Phase A window (CHG-008 r4 rule:no parallel device operations within a
  window). Same-day sequential windows are fine; each window's evidence stays separate.

## Records and privacy

- Raw streams and OB outputs live in an operator-controlled `0o700` directory outside every git
  repository; files `0o600`; whole-stream SHA-256 recorded.
- Harness commands produce their redacted manifests as usual; OB records are redacted by the
  maintainer (user paths → placeholders; serial only into device-identity fields of future
  hardware-evidence style records; endpoint/port values are not sensitive and stay literal).
- The repo-facing deliverable is a capture record under
  `openspec/changes/chg-2026-015-hdc-readonly-probe-registration/evidence/provenance/**`
  (record + hashes + redacted manifests), merged by the maintainer via an evidence PR. That
  merge constitutes the "provenance 已由维护者认可" input that TASK-I15-001's readiness PR will
  cite. TASK-I15-001 itself then turns these inputs into versioned registry entries, fixtures
  and receipts per its task contract.

## Stop conditions and prohibitions

- hdc executable hash/version drift from the pinned M0B tuple; ambiguous server process (more
  than one candidate); harness refusal — stop, record, no improvisation.
- No server lifecycle/subserver commands (`kill`, `start`, `spawn-sub`, `killall-sub`); no
  device commands beyond the two list-targets ids; no private-key access; no ad-hoc commands
  outside the harness allowlist and the fixed `OB-*` list; no raw sensitive bytes in git.
- This plan makes no compatibility, conformance, support or release claim, and does not change
  TASK-I15-001's `blocked` status.
