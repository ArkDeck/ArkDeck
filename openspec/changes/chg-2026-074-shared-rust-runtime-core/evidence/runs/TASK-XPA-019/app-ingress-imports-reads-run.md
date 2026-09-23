# TASK-XPA-019 — App ingress admits Import uploads, quota, Trace cache and Debug probe

Base: protected main `7d6382c9e17240804ab9ff601607685be7af8d0e` (#2129).
Branch: `agent/xpa-019-app-ingress-imports-reads`.

The authenticated standalone App ingress now forwards the eight methods the
signed App already sends, whose Rust routes and owners exist, but which the
ingress refused: a HAP or native library upload from the Debug workspace, the
recording quota read, the Debug probe, and Trace cache status and purge. Each
admitted request is checked against its exact closed shape and reaches its owner
exactly once. No protocol schema, Catalog operation, device authority or App
source changes.

## Verified method list

Method: every name in `spec/control/methods` (105) matched against the string
literals in `Packages/ArkDeckKit/Sources/ArkDeckClientKit/**` and `ArkDeckApp/**`
(all App XPC traffic goes through ClientKit `RuntimeXPCRequestTransport`), then
against the ingress allowlist and the `handle_frame` routes of `arkdeck-control`.
Parameter shapes were read from the sending code.

| Method | App sender | Rust route and owner | This change |
| --- | --- | --- | --- |
| `artifact.import.begin`, `.append`, `.abort`, `.commit` | `RuntimeAppArtifactUpload` (Debug HAP and native library; Flash bundle) | `import_resource` → `ImportUploadStore` (begin/append/abort/commit with its `app_owned` provenance) | admitted, HAP and native library only |
| `artifact.quota` | `DeviceControlFacade.artifactHeadroomBytes` (`params: {}`) | `artifact_quota` → `ArtifactUsage::quota` | admitted |
| `debug.probe` | `DebugApplicationFacade.refreshWorkspace` (`targetId`) | `debug_read` → adopted HDC route, fixed `bm dump -a`/`fport ls`/`rport ls` | admitted |
| `trace.cache.status`, `trace.cache.purge` | `RuntimeTraceCacheApplicationFacade` (no params) | `trace_cache_status`/`trace_cache_purge` → `TraceCacheStore` | admitted |
| `trace.probe` | Overview capability, Trace workspace | no Rust route (falls to the foundation refusal) | not admitted: queue slice 3 |
| `flash.bind-current-loader`, `.bootloader-status`, `.device-access`, `.lanePlanPreview`, `.prerequisites` | Flash and Rockchip facades | no Rust route | not admitted: Flash (M4) |
| Flash bundle upload (`artifact.import.begin` with `kind: flash-bundle`) | `FlashApplicationFacade` | owner exists, but publication is not configured for it | refused before the owner; deferred to the Flash (M4) slice |

Every other method the App sends was already admitted. Swift's App XPC allowlist
(`AgentXPCContract.forwardable*Methods`) forwards all eight.

## Closed shapes

As #2126: exact key set, then types, then canonical decimal strings, then the
method's contract schema. The recorded request schemas also admit `owner` and
`artifactId` (and `rawCommand` for the probe, `path` for purge); the App never
sends them, and the ingress refuses them.

- `begin`: exactly `schemaVersion`, `importRequestId`, `kind`, `targetId`,
  `bindingRevision`, `deviceProfile`, `name`, `byteCount`, `sha256`; strings
  except `deviceProfile` (string or null); `bindingRevision` and `byteCount`
  canonical positive. `kind` other than `hap`/`native-library` answers
  `admissionDenied` with `{phase: preAdmission, newDispatchCount: 0}`, Swift's
  App-transport refusal.
- `append`: exactly `importId`, `generation`, `offset`, `byteCount`, `sha256`,
  `base64`; `generation` and `byteCount` canonical positive, `offset` canonical
  non-negative.
- `abort`: exactly `importRequestId`, `generation`; `commit`: exactly
  `importId`, `generation`; `generation` canonical positive.
- `artifact.quota`, `trace.cache.status`, `trace.cache.purge`: no parameters.
  `debug.probe`: exactly a string `targetId` (Control still bounds it).

Identity, name, digest, byte bounds, binding and generation remain the owner's.

## App ownership of Imports

`arkdeck-control` gains `Control::handle_app_frame`, which the App ingress now
uses for every admitted frame. Its origin comes from the authenticated XPC
connection, never from the frame, and it never holds a foreground console. Only
its Import methods answer differently: they reach the new
`HostServices::app_import_resource` (default: `operationUnavailable`, zero
dispatch), never `import_resource`. The local socket keeps `import_resource`.

The agentd `Host` answers `app_import_resource` with the same owner call as the
local path but `app_owned = true`, which is Swift's `RuntimeImportControlGateway`
provenance: the owner writes `appOwned: true` atomically with an App-begun
Import, so the ownership survives a daemon restart, and it refuses to append to,
abort, commit or replay the begin of an Import that is not App-owned, on its first
read and before any write. Discovery, inspection and release are not admitted
through the App, so another client's Imports are neither visible nor operable.
The binding is to the App transport identity (the libxpc code requirement plus
the owner's euid), as in Swift.

Declared differences from Swift, both fail closed with zero dispatch and no
write:
- Swift's gateway pre-reads the record and answers a foreign Import with
  `phase: preAdmission`; Rust answers the owner's own refusal (same code,
  `admissionDenied`) with `phase: importOwner`.
- Swift's gateway answers a concurrent duplicate begin with `resourceConflict`;
  the Rust owner serializes begins and replays the same Import.

## Lost replies

The ingress keeps no Import state: the owner's record is the ownership. An
Import or purge reply is returned exactly as the owner wrote it, never recorded,
repeated or rewritten, so a commit whose answer is lost is neither retried nor
reported as success or as a pre-admission refusal. ClientKit already sends no
retry after a lost commit, and reads Trace cache status after an uncertain
purge.

## Tests

`rust/crates/arkdeck-agentd/src/app_ingress/import_tests.rs` (real Import,
Target, Artifact, Job, storage, Trace cache and Debug owners; synthetic peer):

- `app_uploads_publish_once_as_app_owned_and_keep_their_owner_across_restart`:
  begin/append/commit of a HAP through the ingress, three owner calls, one
  publication, receipt and bytes checked, record `appOwned: true`; a native
  library upload begun before a restart is aborted by the App after it.
- `the_app_operates_no_import_it_did_not_begin_and_writes_nothing_trying`: a
  local (CLI path) upload is refused to the App for begin replay, append, abort
  and commit (`admissionDenied`, `importOwner`, zero dispatch); no Import write
  step reached, the whole root byte-identical; the local client then commits it.
- `a_lost_commit_answer_reaches_the_owner_once_and_is_never_rewritten`: the
  owner loses its answer after the durable receipt; the App gets the owner's
  `recordUnreadable`/`importOwner`, and the commit intent, publication and
  receipt steps each ran once, one Artifact published.
- `malformed_uploads_other_kinds_and_foreign_peers_never_enter_the_owner`: every
  missing key, wrong type, extra key (`owner`, `artifactId`, `appOwned`,
  `peerEUID`), non-canonical count, other kinds (Flash bundle, patch, unknown)
  and foreign peers (other euid, pid 1, foreground console): zero dispatch, no
  write step, root byte-identical.
- `every_admitted_request_reaches_its_one_owner_exactly_once`: a recording host
  sees each of the eight requests once with its exact parameters; App Import
  frames never reach `import_resource`; uncertain owner answers
  (`recordUnreadable`, `outcomeUnknown`) cross unchanged.
- `app_reads_and_trace_maintenance_answer_from_the_production_owners`: quota and
  status byte-equal to the local socket's answer; purge; a purge whose owner root
  was replaced answers `outcomeUnknown`/`traceCacheOwner` once and touches
  nothing; the probe runs exactly its three fixed reads on an inert local HDC
  script (no server process).

`app_ingress::tests::rejected_origins_methods_frames_and_parameters_never_enter_control`
admits the eight methods and adds their closed-parameter refusals.
`arkdeck-control` `only_app_frames_reach_the_app_import_owner_and_never_a_console`
proves the origin split, the unchanged answer of other methods, the default
refusal and that an App `human-action.resume` never takes the console path.

Mutations (each restored by checksum): Host passing `app_owned = false` for the
App fails the two ownership tests; the ingress using `handle_frame` fails three;
dropping the kind check lets a Flash bundle begin reach and be recorded by the
owner (caught); dropping the exact shape fails the malformed test; retrying a
failed commit once turns the lost answer into a fabricated success (caught by
two tests).

## Local targeted checks

Cargo uses `CARGO_BUILD_JOBS=2`, isolated target
`/private/tmp/arkdeck-1330-rust-target`, manifest `rust/Cargo.toml`. Developed
on `20abb8553`; after rebasing onto the base above (#2129 changes only
`arkdeck-platform` calendar code, soak and its run record) fmt, clippy and the
full test run were repeated with the same results.

- `cargo fmt --all --check`: exit 0.
- `cargo clippy -p arkdeck-control -p arkdeck-agentd --all-targets -- -D warnings`:
  exit 0; `/private/tmp/arkdeck-s9-clippy-rebased.log`. (`arkdeck-agentd` is the
  only dependent of `arkdeck-control`.)
- `cargo test -p arkdeck-agentd --bin arkdeck-agentd -- app_ingress`: exit 0,
  25 passed; `/private/tmp/arkdeck-s9-agentd-ingress.log`.
- `cargo build -p arkdeck-cli`, then
  `cargo test -p arkdeck-agentd -p arkdeck-control --no-fail-fast`: exit 0,
  agentd 91 (74 unit, 17 process), control 26;
  `/private/tmp/arkdeck-s9-test-all-rebased.log`. No orphan fake HDC server
  (`ps -axo ppid=,command=` PPID 1 under `arkdeck-managed-hdc-unit-`: 0) and no
  leftover test root.
- Mutation logs: `/private/tmp/arkdeck-s9-mutation-{a,b,c,d,e}.log`, each exit 101.
- `sh scripts/check-sdd.sh`: exit 0, 0 errors and 0 warnings;
  `/private/tmp/arkdeck-s9-sdd.log`.

Not run: `generate-contract.py --check` and `check-contracts.py` (no contract
input changed); Swift and App (no Swift change; the App already sends these
shapes); signed Mach acceptance (needs an independent login or VM).

`rust/scripts/check-import-upload-owner.py` (not in CI) was also run against the
built daemon and CLI and fails at its commit step, independently of this change:
it was written before the Rust commit owner existed and still expects commit to
be `operationUnavailable`; its fixture Import belongs to Target
`TGT-83405c84ff74`, absent from the direct Target fixture, so commit's binding
re-resolution answers `resourceConflict`, which the published
`artifact.import.commit` vocabulary does not contain, and Control normalizes it
to `internalError`. The local Import path here passes `app_owned = false` as
before. Log: `/private/tmp/arkdeck-s9-import-owner-harness.log`.

## Known gaps

- The published `artifact.import.commit` error vocabulary lacks owner refusals
  the App can meet (`resourceConflict`, `artifactIntegrityFailed`,
  `quotaExceeded`, `resourceNotFound`); they reach the App as `internalError`
  ("the result does not conform to the current contract"). Still a failure,
  never a false success; widening needs a recorded Swift frame (contract input).
- Flash bundle uploads, `trace.probe` and the `flash.*` reads stay refused.
- The standalone composition that would serve these owners without an isolated
  development root does not exist yet (queue slice 6).

These are host integration checks with a synthetic peer context, not signed
Mach/XPC identity evidence or REAL_DEVICE_PASS. No installed service or device
was accessed.

## CI

Pending the agent-branch PR and current-head CI. Full unified checks run in CI;
pending or skipped jobs are not passes. Maintainer review remains required.
