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

Export and list disagree about the same catalog: the export path completes with
`catalogStatus.blocker: unaccountedSessionContent` reported in its own result,
while list and show refuse on that identical condition. Both behaviours are
defensible on their own; together they are inconsistent, and which one is
correct is a product decision rather than a defect this Task can settle.

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
| SVC-AC-05 current durable formats | **export leg met; list/show leg not met** | A production caller publishes a Session, and the exact finalized export now completes through published typed operations with the source preserved and the device identifier redacted to a schema-valid form. `session list`/`session show` remain refused by the preserved incomplete 2026-08-02 Session. The earlier record's "no production caller publishes a Session" is superseded. |
| SVC-AC-07 evidence integrity | met, re-read on this build | `job-5b91a6a9f87b23fc689aa12584469758` publishes `artifactIntegrityFailed` rather than `verified`. |

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

### The remedy is an operator action, not a code change

The credential must be rebound to the registered project. `runtime signing
install` takes `--project-ref`, so the path is to reinstall it against
`project-fd677365f7bdefabda66a3c1` with the same keystore, certificate, profile
and key alias. That needs the credential material and its passwords, so it is the
maintainer's action; it was not performed in this window and no credential was
entered, installed, removed or migrated.

## A GJ-1 leg that is still not demonstrated

The execution `gj1-har-20260908` exists on this host and completed, but it did
not exercise GJ-1 §2.1. `agent status --execution-id gj1-har-20260908` reports
`humanAction: null`, and `job timeline --job job-2aabc8981b1b1cb91552a13d098854a5`
is a straight `jobCreated → queued→preflight → preflight→running →
running→finalizing → finalizing→succeeded` with no waiting state and no resume.
The execution is named for the leg it was meant to cover; the record it left does
not show that leg being taken. It is recorded here as **not demonstrated**, and
the physical detach and reattach it needs is still outstanding.

The same execution's `job.sessionPublication` reports
`state: failed`, `reasonCode: sourceIntegrityFailed` — unrelated to the export
work above, and not investigated in this window.

## Still required before this Task can be done

1. GJ-4's second gate: `flash.full-restore@1` is Catalog-`unavailable` for want
   of a named hardware acceptance campaign — a maintainer decision.
2. GJ-5. Its blocker is now diagnosed above: the signing credential is bound to
   `demo-app`, which is not a registered project, and must be reinstalled
   against `project-fd677365f7bdefabda66a3c1`.
3. GJ-1 §2.1 HAR crash-resume, which `gj1-har-20260908` did not exercise.
4. A product decision on the preserved incomplete Session: today it blocks
   `session list` and `session show` on a Runtime whose export path works.
5. The Windows read-only chain, which needs a Windows 11 x64 host, a signing
   identity and a DAYU200 that this window did not have.

Local captures for this window are under `/private/tmp/arkdeck-svc-20260909/`
(`before/`, `after/`, `gj/`, `export-dest/`). They are not committed; the
identities, exits and digests above are what makes the window re-checkable.
