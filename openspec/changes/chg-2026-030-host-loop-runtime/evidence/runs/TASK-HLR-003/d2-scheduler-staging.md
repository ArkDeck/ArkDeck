# TASK-HLR-003 D2 scheduler staging receipt

```text
task:        TASK-HLR-003
operator:    lvye (every mutation typed by hand in the operator's own terminal)
agent role:  plan drafting + read-only observation tooling + receipt verification
authority:   readiness r4 = PR #549, merge ae597d0da7ee53ba8e2e8e6b7ad85554330b53a8
             (lvye APPROVED @ exact head c9191cc3fb98c15d889f4023a4a9089750b83368,
             merged 2026-07-26T02:09:07Z, mergedBy=lvye, auto_merge=null),
             over r3 = PR #547, merge 5307d1b9833333952ae54f41256764394d66f692
window:      2026-07-26, single continuous session; phase receipts span
             02:35:26Z -> 04:27:40Z, sudoers closure re-baselined after the
             terminal decision
terminal:    left-running  (both units stay loaded; no further change to either
             unit before the next merged authorization)
tooling:     ~/hlr003_window.py (read-only observer; selftest 21/21;
             executor_sha256 recorded inside every JSON receipt)
```

## Authority, drift and dispatch-authority binding

- A1–A4: `--r4-merge-oid` full OID; carrier is an ancestor of live `origin/main`;
  carrier touches only `openspec/changes/chg-2026-030-host-loop-runtime/tasks.md`;
  tasks.md provenance recorded — audit-base blob `327d84139ea6989674e3966e636a8fc38c90d3a2`
  → merged blob `fb81c1e40cf0b77d6576450397361473684a2e82`, diff confirmed as the
  r4 block by the maintainer's own review of #549.
- B1/B2: `HEAD == git ls-remote origin refs/heads/main == ae597d0d…` at preflight
  and at install time; `git status --porcelain` empty over all seventeen
  drift-gate paths plus `openspec/changes/*/tasks.md`.
- B3 (standing, unchanged): this binding is the window-period compensating
  control, not a fix; "the loop reads governance inputs from a writable
  worktree" remains owned by HLR-004/005.
- C1: **all seventeen r4 drift-gate blobs equal their pins** at
  `ae597d0d…`, including `hostloop_minter = 4150401c5f875ac282d38d6f70eb4c0c35f97689`.

## Phase log (every launchctl command carries its domain)

### Phase 0 — zero host mutation (receipt `d2-preflight.json`, 22 checks, PASS)

Absence, each row measured in its declared domain:
`com.arkdeck.host-loop.runtime` print exit **113 in `gui/501` AND in `system`**;
`com.arkdeck.host-loop.refresh` print exit **113 in `system`**;
`print-disabled` host-loop entries **0 in both domains**; `~/Library/LaunchAgents`
8 entries, host-loop 0; `dscl` `arkdeckhlr` = eDSRecordNotFound;
`agent/host-loop/**` remote refs 0; `agent/task-hlr-003*` remote branches 0;
token file and sidecar absent.

Baselines: PEM `sudo ls -l` observed by the operator: owner `root`, mode `600`
(typed into the receipt; the path is deliberately recorded nowhere).
`sudo -l -U <operator>` sha256 `a851ae55d6cd5b463a694a965f67253a79492ddfe1a7762c282b757fae0fcd15`;
`/etc/sudoers.d` empty. App-identity GitHub baselines: PRs 1, Issues 1
(the historical HLR-002 probes #514/#515).

Manual confirmation M1 (operator): `/Library/PrivilegedHelperTools` is **not**
the PEM staging directory.

### Phase 0.5 — minter install + first mint (receipt `d2-install-verify.json`, PASS)

```text
git show HEAD:scripts/host_loop/mint_installation_token.sh > /tmp/mint.$$   # worktree deliberately not used
sudo install -o root -g wheel -m 0555 /tmp/mint.$$ /Library/PrivilegedHelperTools/com.arkdeck.host-loop.mint.sh
```

r3 Ordering obligation, all three into the receipt:
**installed sha256 = repo sha256 = `5b8cbc06e7246c83c273f37dd78b07c2eca1e91b541cc88532c9f3c6f5cd9671`
@ main OID `ae597d0da7ee53ba8e2e8e6b7ad85554330b53a8`**; in-repo blob equals the
r4 pin `4150401c…`. Installed file `-r-xr-xr-x root:wheel`, link count 1; token
directory `0700`, operator-owned.

First manual mint (root, `sudo /bin/sh <minter> --app-id 4388667
--installation 148855345 --pem '<operator-only>' --out <token file> --owner
<operator>`): exit 0, `minted`, sidecar `expires_at=2026-07-26T03:39:25Z`.

### Phase 1 — manual foreground round (receipt `d2-phase1.json`, PASS)

Interpreter (byte-pinned for Phase 3): `/opt/homebrew/bin/python3`.
`ARKDECK_HOST_LOOP_CURSOR_ISSUE` explicitly unset.

`--once` → **exit 10**, stdout exactly one line, state `idle`, no write-state,
no absolute path, no secret shape:

```text
host-loop: idle task=None pr=None :: only never-claim tasks are ready (['TASK-HLR-003']); discovery excludes this task's own implementation by readiness rule
```

`--explain` → exit 10, `claimable=none`. The per-gate enumeration required by
r3 (exit 10 alone is not sufficient evidence):

```text
change=CHG-2026-030-host-loop-runtime approved=True local_head=ae597d0da7ee53ba8e2e8e6b7ad85554330b53a8 (advisory; no ls-remote)
done_task_ids=83 (active + archived changes)
  TASK-HLR-001: rejected
      - status 'done' is not ready
      - decision grade 'unknown' is not dispatchable
  TASK-HLR-001A: rejected
      - status 'done' is not ready
      - decision grade 'unknown' is not dispatchable
  TASK-HLR-002A: rejected
      - status 'done' is not ready
      - decision grade 'unknown' is not dispatchable
  TASK-HLR-002B: rejected
      - status 'blocked' is not ready
      - no declared allowed paths
      - decision grade 'unknown' is not dispatchable
  TASK-HLR-002: rejected
      - status 'done' is not ready
      - decision grade 'unknown' is not dispatchable
  TASK-HLR-003: rejected
      - never-claim: the readiness forbids claiming this task
      - decision grade 'unknown' is not dispatchable
  TASK-HLR-004: rejected
      - status 'blocked' is not ready
      - dependencies not done: ['TASK-HLR-003']
      - decision grade 'unknown' is not dispatchable
  TASK-HLR-005: rejected
      - status 'blocked' is not ready
      - dependencies not done: ['TASK-HLR-003', 'TASK-HLR-004']
      - decision grade 'unknown' is not dispatchable
claimable=none
```

`--change` was the compensating-control constant
`CHG-2026-030-host-loop-runtime` throughout (scheduler plist argv carries no
`--change` override; the default is this change).

### Phase 2 — root refresher unit, `system` domain (receipts `d2-phase2.json`, `d2-phase2-after-probe.json`, PASS)

```text
sudo install -o root -g wheel -m 0644 <plist> /Library/LaunchDaemons/com.arkdeck.host-loop.refresh.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.arkdeck.host-loop.refresh.plist
sudo launchctl kickstart -k system/com.arkdeck.host-loop.refresh   # exit 0
```

Verified: plist root:wheel 0644; `ProgramArguments` = `/bin/sh` + the pinned
minter path, exactly one `--pem`; `StartInterval` 1800; `RunAtLoad` true;
stdout/stderr to the root-owned `/var/log/arkdeck-host-loop-refresh.log`.
Service present in `system` (print exit 0). Token file `0600`, operator-owned,
link count 1; directory `0700`; sidecar carries `expires_at` + `token_sha256`
and no token value; the token file's own digest equals the sidecar digest.
Log non-empty and free of token/JWT shapes (the kickstart run printed
`fresh: … not re-minting` — correct freshness behaviour for a minutes-old token).

Negative probe (mandatory): a root-owned **empty** file passed as `--pem`
(the real PEM untouched, unmoved, unrenamed) → **exit 2**
(`JWT signing failed`), and the existing token was untouched:
before == after == `cf61401622fe1fff79fd784198b458cf6f7e32a4d2e9950533967eef0df6241a`.
The probe file was removed afterwards.

### Phase 3 — scheduler unit, `gui/501` domain, never root (receipt `d2-phase3.json`, PASS)

```text
install -m 0644 <plist> ~/Library/LaunchAgents/com.arkdeck.host-loop.runtime.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.arkdeck.host-loop.runtime.plist
```

Verified: plist operator-owned 0644; `ProgramArguments` exactly
`[/opt/homebrew/bin/python3, -m, host_loop, --once, --repo-dir, <repo>]` —
byte-identical interpreter to Phase 1; environment holds **exactly**
`ARKDECK_HOST_LOOP_TOKEN_FILE, ARKDECK_REPO, PYTHONPATH, PATH, HOME` and no
`ARKDECK_HOST_LOOP_CURSOR_ISSUE` (`HOME` is set for `~/.gitconfig`, the r3-
corrected rationale); `StartInterval` 900; `WorkingDirectory` = repo; stdout/
stderr paths set. Service present in `gui/501`, running as the operator's uid
(a gui-domain agent cannot run as root; no `uid = 0` line observed).

Observation: **5 rounds logged, every one `idle`/exit-10 family, none in a
write state**; log free of secret shapes and absolute paths; between-round
`pgrep -fl host_loop` empty. GitHub increments **all zero**: App-identity PRs
1→1, Issues 1→1, `agent/host-loop/**` refs 0.

Negative probe (mandatory): token file parked away, one
`launchctl kickstart -k gui/501/com.arkdeck.host-loop.runtime` → the round
failed **visibly** in the stderr log and created nothing:

```text
host-loop: setup/round failure: cannot read the token file: [Errno 2] No such file or directory: '<token file path under the operator home>'
```

Token restored immediately after; subsequent rounds returned to `idle`.

## Concurrency observable — UNPROVEN, recorded honestly

r3 defines the non-concurrency observable as run_id+pid line prefixes; the
merged #548/#524 code emits none, so the observation cannot be produced. Per
r3's own fallback clause and the r4 recording rule this receipt records it as
**unproven**, with two structural facts in its place: launchd never starts a
second instance of a label (an overdue `StartInterval` firing is skipped while
the previous instance runs), and `--once` is a short-lived process — the
between-round sample observed none resident.

## Token lifecycle observed

First manual mint `expires_at 03:39:25Z`; final sidecar
`expires_at 2026-07-26T04:57:10Z` — at least one re-mint demonstrably occurred
during the observation period, i.e. the refresher's freshness logic ran live.
The stderr log contains **exactly one** failure line for the whole window: the
deliberate token-removal probe. Zero 401/Refused lines were observed in either
log.

## Sudoers closure (window start vs after the terminal decision)

`sudo -l -U <operator>` sha256 before and after:
`a851ae55d6cd5b463a694a965f67253a79492ddfe1a7762c282b757fae0fcd15` — identical.
`/etc/sudoers.d`: empty before, empty after. **No sudoers rule was added.**

## Presence matrix (before → after, with domains)

```text
runtime  gui/501:  113 -> 0      (loaded, running as the operator)
runtime  system:   113 -> 113    (never existed in system)
refresh  system:   113 -> 0      (loaded)
arkdeckhlr:        absent -> absent  (retired reservation, never created)
~/Library/LaunchAgents: 8 entries -> 9 (the runtime plist; nothing else)
workerDisabled:    true (HLR-002 reservation) -> scheduler ACTIVE; dispatch
                   remained 0 by gate evaluation, evidenced per round above
```

## Negative probes (r3 list, each with its observed value)

- dispatch = 0 (5/5 rounds `idle`; `--explain` `claimable=none`)
- `agent/host-loop/**` ref writes = 0 (`ls-remote` count 0 at preflight,
  phase 1 and phase 3)
- Issue/PR create or edit = 0 (App-identity counts 1→1 / 1→1)
- review/approve/merge/auto-merge/update-branch/protection/ruleset/admin = not
  exercised; runtime facts stand in per r3: the frozen route allowlist and
  `forbidden_capability_count` are properties of `worker.py`/`transport.py`,
  whose blobs equal the r4 pins (C1) — no route was added or widened
- App permission / PEM storage change = 0 (E1 baseline unchanged; App
  permissions untouched — the only token minted carries the pinned four
  permissions by construction)
- new sudoers rules = 0 (byte-identical baselines above)
- legacy `agent-pr.yml` behaviour change = 0 (blob equals pin
  `a514d9e539964f9e1960acbe4ffaa696629571da`)

## Honest registrations and deviations

1. The PEM path appears in the root refresher's argv and in the world-readable
   LaunchDaemon plist — the visibility change r3 registered in advance. The
   path itself appears in no receipt and no repository file.
2. The minter install path is public by the r4 pin and is quoted here; M1
   confirms it is not the PEM directory.
3. The runtime stderr log (a host-local, operator-owned file) contains one
   absolute home path inside the OS `Errno 2` message quoted above; receipts
   redact it to `~` and carry no absolute paths. A post-copy re-verification
   of all six JSONs found zero actual paths and zero secret shapes (the only
   `/Users/` matches are the literal rule descriptions inside two check
   names).
4. S9 concurrency: unproven (section above).
5. Agent pre-validation: the observer tool was run twice in `--agent-dry-run`
   mode before the window (zero mutations): once **pre-merge, correctly
   STOPping** on "r4 carrier branch still present remotely", once post-merge,
   PASS. Those dry-run receipts stay outside the evidence set because their
   `operator` field is the tool default, which would misattribute the runs.
6. Timing note: the first token expired (03:39:25Z) inside the observation
   period; the freshness margin re-minted it (final `expires_at 04:57:10Z`)
   and no round failed on it (zero 401 lines). Recorded as observed; the
   per-firing schedule lives in the host logs.

## What was NOT done

No Phase 4 and no cursor Issue (no `--cursor-issue`,
`ARKDECK_HOST_LOOP_CURSOR_ISSUE` absent from the unit environment — S3); no
dispatch; no lease ref was created (rollback's lease clause never applied); no
legacy creator exit; no review/merge/auto-merge/admin route; no GitHub
settings/protection/ruleset change; no App permission or PEM storage change;
no `sdd-guard.yml` or governance text change (this PR adds evidence files
only); **no `Decision-Grade` line was written by anyone** — the
`@unittest.expectedFailure` marker remains the honest record of that gap.

## Terminal state

**`terminal=left-running`**, declared by the operator. Both units remain
loaded exactly as verified above; until the next merged authorization (r5 /
the HLR-004 readiness) neither unit, plist, token path, minter nor PEM may be
touched. This receipt does **not** claim TASK-HLR-003 done, does not claim any
live first-PR proof (ownership stays deferred to r4 + the HLR-004 readiness,
per r3), and does not alter any task status.

## Receipt manifest (sha256)

```text
c65c96e714509f689e207f39e1fab8f0b124ad0181430367fed9426b170e7140  d2-install-verify.json
4a64125d3eb8ec2f91bb6709e2cc2f0c3c1c1ed62817a802adda1d1ce9a650f4  d2-phase1.json
5e5739944cffe6a3127854a93d286d21de688ca76ec55ad7dba7defae6a44fb9  d2-phase2-after-probe.json
eb926bdec7b6b5068f41637c2e0679b78231908c9a4cb4fc9abb2a5e9b652752  d2-phase2.json
eee86e665030a24388ba6910206761afb06b8286cdbe75a38945c76463ca8dab  d2-phase3.json
0ea5e9828800704428a652b91c722713f23d9784fe2a733f37a8b79c68b6877a  d2-preflight.json
```
