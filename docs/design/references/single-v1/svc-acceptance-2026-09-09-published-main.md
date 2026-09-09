# SVC acceptance on the published `5933ba84` build — 2026-09-09

An execution record for `TASK-SVC-005`. It does not mark that Task done and does
not mark CHG-2026-075 verified. This window was host-only: no device was
connected, so no Journey result here is a device result. Journey outcomes from
earlier windows stay attached to the builds they were taken on and are not
restated as current.

What is new: **`session export apply` passes on the published Runtime.** It was
the last blocker on SVC-AC-05's export leg and had failed on every previous
attempt.

## What was installed

The checkout was clean at protected `main`
`5933ba84d6226eed596ea7325f3c9d40500d5326` (`git status --porcelain` empty),
which is #1799. `Packages/ArkDeckKit/Distribution/macOS/build-local-helpers.sh`
built the helper pair from that tree with the Developer ID identity `8AQTYW5FKR`
and the two ArkDeck helper provisioning profiles; nothing else was installed.

| Identity | Value |
| --- | --- |
| Swift commit | `5933ba84d6226eed596ea7325f3c9d40500d5326` |
| CLI executable SHA-256 | `7ebd00a7c0d6e6797b7ba0ef4bc054aa0dcd7196c5f3f040669b2aaad9c4d2c9` |
| Daemon executable SHA-256 | `811cad2e762ad891ed985f04826c4fffde2b3f31303aaedf2c07bfe5a5753c81` |
| Installed at | `2026-09-09T00:55:14Z`, `runtime service update --daemon`, exit 0 |
| Control protocol | `1.0.0` |
| Contract identity | `8a662759721a2081e974306399997801246de4022047365c050107de5dce2912` |
| Runtime Catalog digest | `508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684` |
| Pinned HDC SHA-256 | `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83` |

The installed daemon's on-disk SHA-256 was read back and equals the built one
exactly. The install receipt preserved the ArkForge lane
(`ArkForge-3f5b48cd-20260902.bundle`) and the ArkTrace descriptor unchanged.

`job list` returned the same 21 Jobs with the same outcomes before and after the
update, including the three `waitingForRecovery` Jobs
(`job-176e1924577288f076562d33b44c6e9f`,
`job-c9274a31cb5ba7c8aad61451416af4f4`,
`job-bf0b748ef707e7e2ca80d8063959e6d1`), which were read and left as they were.
No Job was created, replayed, reconciled or relabeled in this window.

## Session publication and export

`session export apply` had failed on this host on every attempt. The published
Session's `inspect-git-status` step carries a `projectRef` equal to its Job's
target id, so the manifest's device-identifier set contained it; redaction
rewrote it to the free-text `[REDACTED-DEVICE-ID]` sentinel, whose brackets no
ArkDeck identifier may contain, and the exporter's own `SessionManifestDocument`
validation refused the manifest it had just built. #1799 completed the two
redaction key lists and gated them against the validator.

On this build, against the real published Session:

| Command | Exit | Result |
| --- | --- | --- |
| `session export preview --session session-job-71f00adafcce67d0de4eed11ebb4b5c3` | 0 | `previewId 9ee174bb…`, digest `7cea6c0b…`, `estimatedBytes 1563`, `newDispatchCount 0` |
| `session export apply --preview-id … --preview-digest …` | **0** | published to the destination, `resultGeneration 1`, `newDispatchCount 0` |
| `runtime storage status` | 0 | `sessionCount 1`, `unaccountedSessionCount 1`, `usedBytes 4017494998`, `catalogGeneration 1` |
| `session list` | 69 | `operationUnavailable`, naming the offending leaf |
| `session show --session …` | 69 | `operationUnavailable`, same leaf |

The exported product was verified, not assumed:

- The source Session is unchanged: its `manifest.json` still hashes to
  `270bd40d97701cf462c28e473cfa7406ccdfea5872214a560f0fcafd50eabef5`, the same
  `manifestSha256` the preview and the result both report, with
  `journalSha256 121b72d8adcf944dc7eb566c58920f5ef19d98ff94bad5a3a715a40cb239ecc0`.
- The exported `manifest.json` hashes to
  `cac181bfea901bf7045e981ccbcbb23f331afdd2174b25ed73c40526fc46f037`.
- Its `inspect-git-status` step now carries
  `projectRef = redacted-device-aa46c4f072672f57dee812c2` — a value that is
  still a valid ArkDeck identifier, which is the whole point of the fix.
- The original `project-fd677365f7bdefabda66a3c1` does not appear anywhere in
  the exported bytes.

This is a published-Runtime typed operation over the user-private UDS, not a
fixture and not a host script.

### The read leg, closed on a later build

`session show` refused all day for the same reason `list` did. It was grouped
with the whole-root family on the reasoning that each of them "answers about the
whole root", which is true of `list` and not of `show`: the published
`session.show` result carries only that Session's own facts. #1805 answers it at
the scope it asks about, under the same guard the export path already used and
had reviewed, factored so the two cannot drift.

Verified on protected `main` `eadb46b8`, CLI
`33643ee7e540f52b9feb8bc599bd7dfaf73bf68b18f23f31a220021399a0346f`, daemon
`4153ec722359825304afba50484e75ff08c19b3dd2e9f3c24fd31c55e0047ce3`, installed
`2026-09-09T04:32:39Z`:

| Command | Exit | Result |
| --- | --- | --- |
| `session show --session session-job-71f00adafcce67d0de4eed11ebb4b5c3` | **0** | `sizeBytes 5395`, `completedAtUtc 2026-09-08T13:23:16Z`, `expiresAtUtc 2026-12-07T13:23:16Z`, `pinned false`, `generation 1` — and no total over the root |
| `session show --session rockchip-session-42f8e86d-…` | 69 | `operationUnavailable`, naming the leaf: showing the unaccounted Session itself stays refused |
| `session list` | 69 | `operationUnavailable`, naming the leaf: the whole-root contract is unchanged |

So on the published Runtime a healthy Session can now be published, read and
exported while one preserved incomplete directory remains exactly where it is.

### The historical Session, and what it still blocks

`session list` and `session show` still refuse, with
`operationUnavailable` / `newDispatchCount: 0` and the message

> Session catalog contains unaccounted content:
> `2026/08/rockchip-session-42f8e86d-8cbf-4aa0-a411-5e1624e9f291` (unreadable)

That is the 2026-08-02 Session which has an identity record and no
`manifest.json`. It is preserved exactly: nothing under it was moved, deleted,
rewritten or given an invented manifest, and its directory still carries its
original `Aug 2 10:24:54 2026` timestamp. The refusal now names the exact leaf
rather than failing anonymously, which is the diagnosable handling this Task
asked for — but naming it is not repairing it, and `session list`/`session show`
remain unavailable while it is there.

An earlier draft of this record called export completing while list refuses an
inconsistency needing a product decision. That was wrong, and the correction is
worth keeping: the distinction is deliberate and documented in the source — an
answer about the whole root cannot be partial, an answer about one named Session
can be exact. What was actually wrong was `show` sitting on the wrong side of
that line, which #1805 fixed.

## Journey evidence readable on this build

No device was connected in this window, so nothing below is a new device result.
These are the durable Runtime records for the Jobs the earlier windows produced,
re-read through `job evidence` on this build so they can be re-checked without
the local captures, which were in `/private/tmp` and have since been reaped.

| Journey | Job | Terminal | Blockers | Verified artifacts |
| --- | --- | --- | --- | --- |
| GJ-1 observe | `job-06c4e41e2f5177afc96b6cd724b1be37` | succeeded | none | 3 |
| GJ-2 normal | `job-33af2af4715f1d158e0aa985c8328cca` | succeeded | none | 2 |
| GJ-2 confirmed-failure compensation | `job-c4a51d35f513cf0152c5b9cacec01bcb` | failed | none | 2 |
| GJ-3 positive | `job-a48fdb55ba96e68256b566848d39c538` | succeeded | none | 2 |
| GJ-3 rollback | `job-5b91a6a9f87b23fc689aa12584469758` | failed | `artifactIntegrityFailed` | 1 |

The last row is the Job SVC-AC-07 turns on: before #1777 the Agent evidence
surface published `verified` for it. It now publishes its blockers, and
`job evidence` exits non-zero with `Job outcome or evidence requires attention`.

`actualStepKinds` on these records is a deduplicated inventory and does not show
compensations; the Job Journal is the authoritative per-step surface. GJ-3's
rollback attestation is a Journal entry, not an entry in the table above.

## SVC-AC status changed by this window

| AC | Status | Basis |
| --- | --- | --- |
| SVC-AC-05 current durable formats | **publication, read and export all met** | A production caller publishes a Session; `session show` answers for it (#1805); and the exact finalized export completes through published typed operations with the source preserved and the device identifier redacted to a schema-valid form. `session list` still refuses while the 2026-08-02 directory is unaccounted, which is the correct whole-root contract and not an outstanding item. The earlier record's "no production caller publishes a Session" is superseded. |
| SVC-AC-07 evidence integrity | met, re-read on this build | `job-5b91a6a9f87b23fc689aa12584469758` publishes `artifactIntegrityFailed` rather than `verified`. |
| SVC-AC-09 current configuration | **met on the published Runtime** | The credential rebind exercised `workspace preset remove`, `runtime signing status/remove/install --build-profile --project-ref`, `workspace preset register --kind signing` and `runtime service restart` end to end on a Data Protection Keychain credential (the one refusal was #1810's defect, since merged), and the published `8a28f182` build resolved the same preset `active` on its first start. |
| SVC-AC-10 complete delivery | **GJ-5 met on the published Runtime; GJ-4 blocked** | GJ-5 `REAL_DEVICE_PASS` twice: on `8c6a376c` + #1810 (07:56Z) and on the published `8a28f182` build (08:30Z), record `gj-headless-rerun-2026-09-09.json`. GJ-4: the acceptance window was opened under DEC-014 and the flash was refused at admission because the destructive lineage of this target is closed by two 2026-09-07 Jobs still `outcomeUnknown` — section below. |

Every other SVC-AC row keeps the status and the build it was recorded against in
[`svc-acceptance-2026-09-08-published-main.md`](svc-acceptance-2026-09-08-published-main.md).
Nothing in this window re-verified them, and this record does not restate them.

## Residual found while fixing the export

Two were repaired under `TASK-SVC-002` and one is left named.

- The identifier key list was missing twelve of the thirty-seven arguments the
  validator reads as identifiers, and the digest key list was short by six the
  same way — four bytes is enough to match a substring, so a short device
  identity collides with hex by chance. #1799 completed both and added a
  contract test that derives what each list owes from `WorkflowStep`. The digest
  half was found by enumeration, not on this host: the host's one affected
  Session carries only `projectRef`.
- A refusal raised before the destination was replaced was reported as
  `outcomeUnknown` / "requires destination inspection" and consumed the preview,
  although the exporter provably had not written anything. Three previews on
  this host are still stranded in `applying` from attempts that published
  nothing, and #1800 does not retroactively release them. #1800 reports such a
  refusal as confirmed, names its cause and returns the preview to `ready`; it
  also narrows a real contract gap, because `recordUnreadable` is in
  `spec/control/methods/session.export.apply.json`'s error vocabulary and
  `outcomeUnknown` is not.
- Twenty-one further argument keys have character-constrained validators
  (`enumeration`, `constant`, `actionIdentifier`, `remoteAbsolutePath`,
  `partitionName`, `relativePath`, `signingPresetReference`) and no redaction
  rule at all. For a closed enumeration no redaction can be correct, so the
  answer there is a diagnosable refusal rather than a third key list. **No real
  occurrence has been demonstrated** — the only recorded `remotePath` value
  embeds a Job id, not a device identity — so this is a named latent gap, not a
  live defect, and it is deliberately not grouped with the two above.

## Second half of the window: the `5933ba84` → `c3a19631` build

After #1800 merged, the helper pair was rebuilt from clean protected `main`
`c3a196310472cca5f7672155a58e1a80a031724b` and installed the same way at
`2026-09-09T01:15:12Z`, exit 0.

| Identity | Value |
| --- | --- |
| Swift commit | `c3a196310472cca5f7672155a58e1a80a031724b` |
| CLI executable SHA-256 | `c63a35a5b3929e62ae32f5317081d944be98aa11bebe6088e462f261a62dba4c` |
| Daemon executable SHA-256 | `bd274fde36f934d58098842be2a99632ec07599234ce0eb2909c22097f57d20a` |

`session export preview` and `session export apply` were run again against the
same Session on this build. Both exit 0, and the exported `manifest.json` hashes
to `cac181bfea901bf7045e981ccbcbb23f331afdd2174b25ed73c40526fc46f037` — byte
identical to the `5933ba84` export, with the same
`projectRef = redacted-device-aa46c4f072672f57dee812c2`. The redaction is
deterministic across builds.

### #1800 is not exercised by anything reachable from the published surface

The attempt to verify #1800's refusal disposition on the published Runtime did
not succeed, and the reason is worth recording. Two refusals were produced
through published operations only:

| Setup | Exit | Code | Message |
| --- | --- | --- | --- |
| destination parent removed after the preview | 65 | `invalidInput` | Session export parent must exist without symbolic-link components |
| destination occupied by a file after the preview | 65 | `resourceConflict` | Session export destination already exists |

Both left the preview record `ready`, but neither is evidence for #1800:
`applySessionExport` calls `exportDestinationFacts` **before** `markApplying`, so
in both cases the preview was never claimed and had nothing to be returned from.

Every refusal reachable from the published surface appears to be of this kind.
The window the fix addresses opens only once the exporter itself fails, which on
this host required a product defect to reach — the redaction defect that stranded
three previews. So #1800 rests on its contract tests, including the one that
applies the same preview again after a refusal, and on the unified gate; it has
**not** been exercised on the published Runtime, and this record does not claim
it has. The three previews stranded in `applying`
(`export-40cb58fb…`, `export-7295a761…`, `export-cf0395b9…`) are still stranded;
the fix is not retroactive.

## GJ-5's blocker, diagnosed

`workspace.sign-openharmony-hap@1` is the one non-Flash operation still
`unavailable` on this host — 27 of 30 are available, the other two being the
hardware-gated Flash pair. Its blocker had been carried as "the signing preset is
stuck at `runtimeRestartRequired` across a real restart". That description was
accurate and useless; the cause is now established, and it is not a restart.

The chain, each link read from the published surface on this build:

1. `operation list` → `workspace.sign-openharmony-hap@1` is `unavailable`,
   `reasonCodes ['workspace_preset_unavailable']`, `workspace.presetUnavailable`.
2. `workspace preset list --project project-fd677365f7bdefabda66a3c1` → the
   signing preset `preset-23114ce6017f4fbdd8930bcc`, registered
   `2026-09-07T06:50:01Z`, `configurationStatus: runtimeRestartRequired`. The
   build and test presets on the same project and the **same** toolchain
   (`toolchain:sha256:9cee08f1…`) are `active`, so the toolchain resolves.
3. `runtime signing status` → the credential
   `credential:sha256-562430f169…` is `state: available`, `installed: true`,
   **`ready: true`**, `diagnostics: []` — and `projectRef: "demo-app"`.
4. `workspace project list` → exactly one registered project,
   `project-fd677365f7bdefabda66a3c1`. **There is no `demo-app` project.**

In `ArkDeckAgentDaemonMain/main.swift`, a `signing` preset resolves its toolchain
and then its credential, and requires
`credential.projectRef == resource.projectRef`; otherwise it throws
`resourceConflict`, "signing credential project binding changed". The catch
around that loop records
`workspacePresetResolutionFailures[presetRef] = "workspace.presetResolutionFailed:\(error)"`.
A preset is only marked applied when it has no entry there, and
`RuntimeWorkspaceProjectStore.presetResource` projects an unapplied preset as
`runtimeRestartRequired`.

So the credential installed on 2026-09-02 is bound to a project reference that no
longer exists. No restart can change that, which is why several did not.

### Two diagnosability defects this exposes

- The resolution failure is computed and then discarded. What the operator is
  shown, `runtimeRestartRequired`, names a remedy that provably cannot work. The
  reason appears in no other surface either: `doctor` returns nine findings and
  none concern the preset, and `~/Library/Logs/ArkDeck/agentd.log` records
  `workspace ProjectProfiles ready for project-fd677365f7bdefabda66a3c1` with
  nothing about the preset that failed.
- `runtime signing status` reports `ready: true` and `diagnostics: []` for a
  credential no registered project can use, with `referenceCount: 2`.

Both are the same family as the export defect fixed in #1799: the Runtime knows
the reason and publishes something else. Neither is repaired here.
`RuntimeWorkspaceProjectStore.swift` and `ArkDeckAgentDaemonMain/main.swift` are
in no SVC Task's Allowed paths in this change, so the repair needs a scope
revision rather than a quiet widening.

### The remedy is an operator action, not a code change — superseded the same day

> Superseded by the GJ-5 section below: the operator action was attempted through the product and refused by a second defect (a credential owner no preset record carries); #1810 repairs it and the rebind then completed through published leaves only.

The credential must be rebound to the registered project. `runtime signing
install` takes `--project-ref`, so the path is to reinstall it against
`project-fd677365f7bdefabda66a3c1` with the same keystore, certificate, profile
and key alias. That needs the credential material and its passwords, so it is the
maintainer's action; it was not performed in this window and no credential was
entered, installed, removed or migrated.

## GJ-1 §2.1 HAR crash-resume — `REAL_DEVICE_PASS`

Executed on the published Runtime with the real DAYU200 (`TGT-958780b2ffb7`,
OpenHarmony-7.0.0.37), protected `main` `eadb46b8`, daemon `4153ec72…`. The
physical detach and reattach were performed by the maintainer at the two points
the procedure requires.

An earlier draft of this record listed this leg as **not demonstrated**, because
the execution named `gj1-har-20260908` completed with `humanAction: null` and a
straight `queued→succeeded` timeline: it was named for the leg but never took it.
That entry is superseded by the run below, which did.

| Step | Result |
| --- | --- |
| 1. USB detached | `device candidates` exit 0 |
| 2. `agent run --operation observe.device@1 --execution-id gj1-20260909-har`, no `--target` | **exit 75**, `humanActionRequired`, `state waitingForHuman`, `humanAction.category physicalConnection`, `minimumAction human.connectOrPowerDevice`, `reasonCode device.notObserved`, **`newDispatchCount 0`**, `actionId har-c12db578-b15d-449a-a2c3-b3fcfebf5621` |
| 3. client crash simulated | that stdout was sealed unread (`bc3e8d3974ade7bf97da321ce04185804125051dd4612a6e24b30bffa8434547`); its `resumeReference` was never used |
| 4. USB reattached, execution id only | `agent status` → `waiting`, `nextAction.resumeReference resume-3dff6d13-8e67-4761-abf5-558bfa07efab`; `human-action list --owner-kind agentExecution --owner gj1-20260909-har` → exactly one action, same id; `human-action show` → **the identical reference, verbatim** |
| 5. `agent resume --resume-reference …` | exit 0, `state completed`, `jobState succeeded`, `job-49720bb2a6c389007eb44e1998f7160f` |
| 6. after resume | the action reads **`resolvedByFreshProbe`** |
| 7. `job evidence` | `terminalState succeeded`, `blockers []`, `actualStepKinds [probeHostTool, probeHDCServer, probeDevice, runApprovedRemoteRead]`, 3 verified Artifacts |

The binding did not move. All three Artifacts carry `TGT-958780b2ffb7` at
`bindingRevision 2`, the same target and revision as before the detach, so the
reattach was resolved by a fresh probe rather than a rebind — which is the point
of the leg.

The Job ledger gained exactly this one Job: 21 before, 22 after, none removed and
every prior outcome unchanged.

### One correction to the runbook, not to the product

`docs/design/cli-golden-journey-headless-runbook.md` §2.1 step 1 says to confirm
`candidates` is **empty** after the detach. It is not: HDC keeps the entry and the
Runtime republishes it as `authorizationState: Offline`, `adoptedTargetId: null`,
`deviceInformation: null`, `bindingRevision: null`. The HAR fired anyway, and its
`reasonCode` says why — `device.notObserved`, not "the list is empty". The
product behaved correctly; the runbook sentence describes a state that does not
occur, and following it literally would make an operator think the step failed.

## GJ-5 Bounded AI Debug Loop — `REAL_DEVICE_PASS`, first on the candidate build, then on the published Runtime

Executed 2026-09-09 07:56Z–08:01Z with the real DAYU200 (`TGT-958780b2ffb7`,
`bindingRevision 2`, OpenHarmony-7.0.0.37) through published `arkdeck` leaves
only, driven by a host-side script that calls nothing but the CLI
(`/private/tmp/arkdeck-gj-headless-20260909/gj5/driver.py`). The redacted
record is [`gj-headless-rerun-2026-09-09.json`](gj-headless-rerun-2026-09-09.json).

**The Runtime under test is not protected `main`.** It is `main` `8c6a376c`
plus `agent/ohs-001-orphan-credential-owner-20260909` (PR #1810, `5e1702f4`),
built locally (`build-local-helpers.sh`, CLI `42c7b992…`, daemon `6e6c4df2…`,
contract identity `8a662759…`, Catalog digest `508783ac…`). #1810 changes only
the daemon's startup reconciliation of the signing credential owner ledger; no
GJ-5 path. The run must be repeated on the merged build before this Task is
done, and the same driver does it in five minutes.

### Why a fix was needed first

The remedy named above — reinstall the credential against the registered
project — was tried through the product and hit a second defect:

| Step | Result |
| --- | --- |
| `workspace preset remove … --preset preset-23114ce6017f4fbdd8930bcc` | exit 0, `removed`; `runtime signing status` `referenceCount` 2 → 1 |
| `runtime signing remove` | exit 1, `signing credential is referenced by an active workspace preset` |
| the remaining owner | `preset-3667528438767fb6b68fd0ad`, the signing preset the 2026-09-02 window registered under the legacy `demo-app` root; no store record carries it (the state directory was retired since), but the credential owner ledger lives beside the signing material and kept the pin. `OpenHarmonySigningCredentialOwner.ledgerForMutation` refuses `install` and `remove` while any owner remains, and the only release path is a store mutation of a preset the store carries — so there was no product path out |

#1810 (`TASK-OHS-001`): the daemon on the default state directory releases,
at startup, every credential owner its preset store no longer carries, and
says so. On this host: `agentd.log` `signing credential owner released presets
no store record carries: preset-3667528438767fb6b68fd0ad`, then
`referenceCount 0`, `runtime signing install --build-profile … --project-ref
project-fd677365f7bdefabda66a3c1` → `credential:sha256-2fa4fa4b…`,
`workspace preset register --kind signing` → `preset-3cae17c26b7aca2c2bfba389`,
`runtime service restart` → the preset `active`, `operation list` **28 of 30
available** (only the two hardware-gated Flash entries left). No file under the
signing root or the state directory was edited by hand. Record:
`chg-2026-057/evidence/runs/TASK-OHS-001/orphaned-credential-owner-20260909.md`.

### The loop

| Hop | Job | Result |
| --- | --- | --- |
| repro `debug.hap@1` (crash-probe HAP `ee083149…`, `retain`, `running`, 20 s diagnostics) | `job-cde216d01fba8c0fd54f7517b6fdb11e` | succeeded, `deviceMutation`, 3 Artifacts |
| liveness 34 s after start (`capture.diagnostics@1`) | `job-18983343b576393eb9ace107bae95143` | `processState STOPPED`, `targetProcessNotRunning`, `pidObserved false` |
| the same with `crashLogs: true` | `job-5fc645325245724ee9f272576d7c3517` | `crash-index.txt` published: 10 Faultlogger entries, the newest a `jscrash` of `com.example.waterflowdemo` |
| `analyzer.extract-crash-signature@1 --target TGT` on that crash-index lease | `job-45ee65fe426b7dd3981bcce2ee930ee5` | `answered`, 5 parsed entries |
| `workspace.prepare-isolated-copy@1` (`expectedWorkspaceRevision` computed locally by the provider's algorithm: `701c5bd9…`) | `job-f7fadc632f9894ae6b3c0da6457fcc30` | copy `evolution-659f702fc0a1dfab0136`, `sourceWorkspaceRevision` echoed equal, isolated revision `e0d4131e…` |
| `artifact import workspace-patch` (`gj5-fix.patch` `b8111bf1…`, 610 bytes) + `workspace.apply-patch@1 --target TGT` on the copy | `job-0606053d21a71b8c53195e485abf6e7d` | succeeded; `previousWorkspaceRevision e0d4131e…` → `workspaceRevision e145d393…`, `entry/src/main/ets/entryability/EntryAbility.ets` |
| `workspace.build-openharmony@1` on the copy, `preset-9cc94c378346e500cb0a0b4a` | `job-62b82ee7ae27fe0c11a6d6e8d0e5b485` | `unsigned.hap` 2 748 896 bytes |
| `workspace.sign-openharmony-hap@1 --target <copy>`, `preset-3cae17c26b7aca2c2bfba389` | `job-7915e6758eb9940a6e9be8008b3cfa3f` | `signed.hap` 2 816 438 bytes, `5cc2c45d…`; `signing-report.json` names the same keystore/certificate/profile digests the credential was installed from |
| `artifact export` → `artifact import hap` → verify `debug.hap@1` | `job-843c84621fff4918a23c4daa5d384518` | succeeded; `install-readback.json` `deployedArtifactSha256 == 5cc2c45d…`, `installed true`, firmware `OpenHarmony-7.0.0.37` |
| liveness 34 s after the fixed start | `job-a35106585f5ddfcde97d9e47f76a1fe7` | **`processState RUNNING`, `targetProcessRunning`, `pidObserved true`**; crash-index still 10 entries — unchanged since the repro |
| negative: same patch lease, `expectedWorkspaceRevision` = the superseded `e0d4131e…` | none | exit 77 `admissionDenied`, `execution stopped before Job creation`, `outcomeUnknown false`; Job ledger 32 before, 32 after, no new Job |

Every criterion of runbook §6 holds: repro `UNHEALTHY`/`targetProcessNotRunning`
with a crash entry and an `answered` signature; isolate, import, patch, build,
sign all `succeeded` with `outcomeUnknown false` and the patch evidence naming
`previousWorkspaceRevision` → new revision; the install readback pinned to the
signed HAP's SHA-256; `HEALTHY` after the crash window with the crash-index
count unchanged; a named refusal with an unchanged ledger. Raw device commands
0, App 0, repository writes 0 (the patch lands on the Runtime-owned copy; the
source `tests/waterflow-demo` is untouched). No HAR, no `outcomeUnknown`, no
`authorizationRequired` — the isolated copy is authorised automatically.

The isolated revision, the post-patch revision and the unsigned/signed byte
counts are identical to the 2026-09-02 record's, which is the expected sign of
a deterministic pipeline over an unchanged source tree, not a copied result:
every Job id above is new and readable on this host.

### Repeated on the published Runtime

After #1810, #1813 and #1814 merged, the helper pair was rebuilt from protected
`main` `8a28f182` (CLI `494e2a35…`, daemon `6035adcb…`) and installed at
`2026-09-09T08:29:37Z` (`runtime service update --daemon`, exit 0; HDC, ArkForge
lane and ArkTrace descriptor preserved, campaign `""`). On its first start the
signing preset `preset-3cae17c26b7aca2c2bfba389` resolved `active` without any
reconciliation, `operation list` read 28 of 30, and the same driver ran the same
inputs under new execution ids (`gj5-20260909b-*`):

| Hop | Job | Result |
| --- | --- | --- |
| repro `debug.hap@1` | `job-88183e9096fcb9338ff006934e5b783f` | succeeded |
| capture after the window, `crashLogs: true` | `job-8be6bf583f218c7a666352e3ea3e869b` | `STOPPED` / `targetProcessNotRunning`; crash-index 11 entries |
| `analyzer.extract-crash-signature@1` | `job-a96c77015f647c0d10cd5cfdef8b639c` | `answered` |
| `workspace.prepare-isolated-copy@1` | `job-2b14340e759ed7e06eb2e2beb0334693` | source revision `701c5bd9…` echoed; isolated `e0d4131e…` |
| `workspace.apply-patch@1` | `job-ab36c5d64096c16e5eb7c4c1f389b297` | `e0d4131e…` → `e145d393…` |
| `workspace.build-openharmony@1` | `job-f747e4bba66b9830351225c2bc7c2fc0` | `unsigned.hap` 2 748 896 bytes |
| `workspace.sign-openharmony-hap@1` | `job-622d66471f0d1ed3097de83266847260` | `signed.hap` 2 816 427 bytes, `b9ff6f88…` |
| verify `debug.hap@1` | `job-89ffb2fb4f0925a6fa2eeb8461dfe662` | `deployedArtifactSha256 == b9ff6f88…`, `installed true`, firmware `OpenHarmony-7.0.0.37` |
| liveness after the window | `job-58e350e329b87b7dda9cbfa23572e63c` | **`RUNNING` / `targetProcessRunning`**; crash-index still 11 |
| negative, stale revision | none | exit 77 `admissionDenied` before Job creation; ledger 41 → 41 |

Same criteria, same outcomes, every Job id new and readable on this host. The
signed HAP's bytes differ from the morning's only by the signature's timestamp.
**This is the run that counts for this Task**; the 07:56Z run stays in the
record as the one that found and cleared the blocker.

## GJ-4 Flash Recovery — `BLOCKED_BY_PRODUCT_DEFECT` (window 08:18Z–08:27Z)

The maintainer gave the go and the window was run exactly as runbook §5 and
DEC-014 say, on the `8c6a376c` + #1810 build:

| Step | Result |
| --- | --- |
| `runtime service update --hdc … --arkforge-bundle … --arktrace-descriptor … --arkforge-campaign gj4-headless-20260909` | exit 0, receipt `campaign: gj4-headless-20260909`; the restart failed twice on the orphaned managed HDC server (`serverDidNotBecomeReady("managed HDC launch could not be bound to its live process identity")`) and launchd's retry brought it up, health `ok` after 30 s |
| `operation list` | **30 of 30 available** — `flash.dayu200` and `flash.full-restore@1` open under the campaign |
| `flash device-access` / `flash bootloader-status` / `flash prerequisites` | no Loader observation; `hdcNormal`, `exactBoundTarget`, `bindingRevision 2`; `loader`, `recoveryPath`, `unlocked` `satisfied`, `stablePower` `unknown` |
| `flash install-binding` | refused `durable binding differs from the only connected Loader; explicit rebind is required`; the existing binding was kept and `--rebind` not used |
| `artifact import flash-bundle --import-request-id gj4-20260909 --device-profile dayu200` | `committed`, `4fd35765…`, 730 783 514 bytes, `imp-56ab6e97-9a3e-4be3-bd63-f75b84f1d13d`, 08:19:33Z–08:21:04Z |
| `flash lane-preview --archive-sha256 4fd35765…` | `state available`, `PLAN-4bbbbc06516a54cc6cdbd401`, `planSha256 6508d876…`, `observationMode hdc-normal` |
| `agent run --operation flash.full-restore@1 --target TGT-958780b2ffb7 --inputs-file gj4.json --execution-id gj4-20260909 --maximum-wait 30m` | **exit 77 `admissionDenied`, `execution stopped before Job creation`**, `state failed`, `jobId null`, `humanAction null`, `outcomeUnknown false` |
| `runtime service update` without the campaign flag | exit 0, `campaign: ""`, `operation list` back to 28 of 30 |
| Job ledger | 32 before, 32 after; **the DAYU200 was not written** |

### Why admission refused, read from the Runtime

`capability list` shows the two destructive envelopes this target already
holds, `CAP-RT-POLICY-13179669…-G1` and `CAP-RT-POLICY-D7876EA9…-G1`, both
`lineageAllowsNewExecution: false`, `lineageBlocker: "use 1 is outcomeUnknown"`.
They belong to the two 2026-09-07 `flash.full-restore@1` Jobs
`job-bf0b748ef707e7e2ca80d8063959e6d1` and `job-c9274a31cb5ba7c8aad61451416af4f4`,
still `waitingForRecovery` / `outcomeUnknown`. Their Journals say why: `HDC
reboot-loader exited but the exact bound Loader was not observed
[hdcExitStatus=0]`, the correlated `arkforged` job terminal remains unknown, and
every reconciliation since — including `job reconcile` on both today, read-back
only — ends in `flash.recoveryProofMissing: no correlated complete-plan receipt;
a model/build readback cannot prove all destructive effects`.

`RuntimeJobEngine`'s automatic destructive policy returns the exhausted
envelope when a generation's terminal is `outcomeUnknown`, so the store's
validation fails closed and the execution is refused before any Job exists.
That is POL-RECOVERY-001 doing its job: a campaign selects the qualification, it
does not lift an unknown lineage (runbook §5 says so in as many words).

### The defect, and the way out

- **The refusal reason never reaches the operator.** `AgentExecutionCoordinator`
  maps the engine's `.rejected` — whose message names the blocked lineage — to
  `failureCode: admissionDenied` and drops the text; the CLI envelope says only
  `execution stopped before Job creation`, `agent status` and the durable
  execution record carry no reason, and `agentd.log` writes nothing. An operator
  has to reconstruct it from `capability list` and two Job Journals, which is
  what this record did. Owner `TASK-SVC-002` (`AgentExecutionCoordinator.swift`
  is in its Allowed paths); publishing the reason touches the closed
  `arkdeck.runtime-agent-execution/1` shape and so needs the `agent.run` /
  `agent.status` schemas re-derived.
- **The way out is the recovery path, not another campaign.** The two unknown
  outcomes can only be superseded by a complete-overwrite recovery that
  publishes a correlated complete-plan receipt — the protected Flash recovery
  invocation of CLI spec §7.7 (`recovery flash-invocation start --request-file …`,
  `evaluate`, `status`; `list` is empty on this host). That is a destructive
  window of its own with its own decision document and was not attempted here.

## Still required before this Task can be done

1. **GJ-4 through the recovery invocation path**, in a window of its own:
   supersede the two 2026-09-07 unknown outcomes with a complete-overwrite
   recovery, then the ordinary runbook §5 flash under a named campaign.
   Everything else for it is in place: DEC-014, the archive import, the lane
   plan and the device prerequisites above.
2. Nothing further on GJ-5, which passed on the published Runtime, and nothing
   further on the preserved incomplete Session.

Nothing further is outstanding on the preserved incomplete Session. It blocks
`session list`, which is the correct answer to a question about the whole root,
and it no longer blocks reading or exporting a healthy Session. The directory
stays exactly as it is.

Local captures for this window are under `/private/tmp/arkdeck-svc-20260909/`
(`before/`, `after/`, `gj/`, `export-dest/`). They are not committed; the
identities, exits and digests above are what makes the window re-checkable.
