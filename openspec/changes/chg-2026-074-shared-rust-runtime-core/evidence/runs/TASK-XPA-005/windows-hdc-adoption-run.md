# TASK-XPA-005 — the Windows consumers adopt the registered HDC tuple, 2026-10-04

The first consumer cut of CHG-2026-078: GJ-1's device hops on Windows read the registered DevEco
Studio 26.0.0.43 `hdc.exe` (`3.2.0g`, c2) by the Windows registry's grammars. It was prepared on
the WHR-002 registration and the XPA-004 census (#2471), and is rebuilt as one commit once both
are on `main`.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. Real `hdc` ran only in the live
process test below, which starts and stops its own server (AGENTS.md, #2454). The test ran twice:
- first without a board;
- then, on 2026-10-04, with the maintainer's DAYU200 attached (HDC-normal image, `USB\VID_2207&PID_5000`).
  Beforehand DevEco Studio was not running, nothing listened on 8710 and no `hdc.exe` ran.

The board was only read: the adoption is the Runtime's own Target write, and no device command
other than `list targets -v` ran. After each run nothing listened on 8710 and no `hdc.exe` ran.

## What changed

- **Grammar by family.** A dispatch names the registered Windows tuple its executable is pinned
  to (`HdcDispatch::registered_windows_tuple`). `ProcessDispatch` names it from its pinned
  digest, on Windows only, and the daemon's `DevelopmentHdc` names its inner dispatch's.
  - The candidate list (`device candidates`, `target adopt`'s snapshot), `observe_device_identity`
    and `observe.device`'s confirmation read a registered Windows tuple's listing with
    `parse_windows_target_list`: the `USB` rows of the six-column family, the UART rows excluded,
    every other form refused whole.
  - That function shares its rows with `parse_registered_windows_presence`, so the two never read
    the same bytes differently.
  - Every other version and dispatch is read by the macOS grammars, unchanged.
  - A Windows host's fakes that are not the registered tuple keep the macOS grammar, which is why
    none of the existing Windows tests changed.
- **The `version` family.** On Windows, `hdc -v` is the registered tuple's exact bytes
  (`Ver: 3.2.0g` CR LF), via `parse_host_client_version`. The Swift-parity line splitter does not
  split at CR LF, so it read the CR LF form as a malformed version. Every other output is read as
  before.
- **Server health.** It stays the commandless observation (`runtime.hdc.status`,
  `doctor --deep`). Measured below.

## Found on the real tool, and fixed

Each of these was found when the live process test first ran the registered `hdc.exe` as the
daemon's managed server, and each is fixed in this cut:

1. **The managed server exited 0 at once.** With the launcher's minimal environment (`PATH`,
   `SystemRoot`, `WINDIR`), `3.2.0g` puts its single-instance mutex file in the temporary
   directory. That resolved to the Windows directory, where it may not write. It logged "Open
   mutex file … failed!!! operation not permitted", then "Other instance already running,
   program mutex failed", and exited 0.
   - `ManagedHdcServer::start` now names `TEMP` and `TMP` (the daemon's own, the account's) to
     the server on Windows.
   - The HDC client commands (`-v`, `list targets -v`, `checkserver`) were measured to need no
     temporary directory.
2. **The managed start's readiness `checkserver` was read as malformed.** It answers
   `Client version:Ver: 3.2.0g, server version:Ver: 3.2.0g` CR LF, the same CR LF splitter issue.
   `parse_host_server_check` reads the registered tuple's exact form on Windows. Only the managed
   start uses it, against its own just-launched server (accepted 2026-10-04); no `checkserver`
   probe is registered.
3. **The commandless identity never matched.** The server receipt names the image
   `\\?\C:\Program Files\…\hdc.exe` (the verbatim spelling). The observer compared it with the
   canonical path stripped of `\\?\`, and the status compared it with the configured plain path.
   So `runtime.hdc.status` answered `hdc.identityUnknown`, then `hdc.identityMismatch`. Both
   comparisons now use one plain spelling (`plain_path`); the digest still names the bytes.

## Not in this cut

- **`probeHDCServer` lowered to the commandless observation.** On Windows the Job owner composes
  no HDC yet (`Host::hdc`, the `HdcComposition` Jobs execute through, is macOS-only), so no
  Catalog operation reaches HDC on Windows today. Lowering the step to the commandless observation
  belongs with composing Windows Job execution over the managed HDC, which is the next cut.
  `observe.device` on Windows stays unavailable until then.
- **The other listing readers.** `live_mode` and `rockchip_hdc` still use the macOS grammar, so
  they fail closed on a Windows listing.

## Tests

- `arkdeck-provider-hdc/tests/windows_hdc_adoption.rs` replays the c2 capture through an
  in-process dispatch pinned to c2:
  - the candidate list, its negatives, and the version bytes on every host;
  - on Windows: candidates (board / UART only / removed), the tool version, the identity
    readback, `observe.device`'s confirmation, and the same bytes from a dispatch pinned to no
    tuple read by the macOS grammar and refused.
- `arkdeck-hoststore/tests/windows_target_owners.rs::the_registered_windows_tuple_capture_is_observed_and_adopted`:
  through the Target observation owner, UART rows only give no observation, and the board is
  adopted once with `toolVersion` `3.2.0g`. Repeated, it answers the same receipt and writes
  nothing.
- `arkdeck-agentd/tests/windows_hdc_live_process.rs` (`ARKDECK_LIVE_WINDOWS_HDC` +
  `ARKDECK_DEV_SIGNER_THUMBPRINT`; without them it says so and checks nothing). The real daemon
  composes the registered `hdc.exe` as its managed server. Through the real CLI, against a
  dev-signed copy:
  - `doctor --deep` reports `hdc.identityObserved`, `available`, `arkDeckManaged`;
  - `runtime hdc status` names the server process, with zero dispatch and no health claimed;
  - `device candidates` returns no observation (the host's UART rows excluded);
  - `target adopt` of the oracle key is refused before admission with zero dispatch, and the
    target list stays empty;
  - after the daemon's stop, nothing listens on 8710 and no `hdc.exe` runs.

  Measured on this host, without a board: pass.
- **The same test with the DAYU200 attached.** The test was first corrected to read the
  observation's real field names (`candidateKey`, `observationContinuity`,
  `snapshotGeneration`). Then it passed:
  - `device candidates`: exactly one observation, `authorizationState` `Connected`,
    `observationContinuity` `relationProven`. The Windows USB census proved the board, the case
    fold matching the upper-case instance suffix to the lower-case connect key.
  - `target adopt` of that observation: `outcome` `adopted`, `bindingRevision` 1. Then
    `target list` names one Target with `toolVersion` `3.2.0g`.
  - `doctor --deep` reports `hdc.identityObserved`, `available`, `arkDeckManaged`.
    `runtime hdc status` reports `availability` `available` with zero dispatch and no health
    claimed (`hdc.commandlessIdentityDoesNotProveHealth`).
  - The connect key, the board serial and the Target id (a prefix of the serial's digest) are not
    recorded here.
- **Coverage.** `WINDOWS_MEASURED_LEAVES` gains `device.candidates` and `target.adopt`.
  `arkdeck maintainer contracts export` moved exactly one entry: `target.adopt` Windows
  `partial` → `implemented`. `device.candidates` has no Windows-required entry. The six
  `cli-feature-coverage.json` pins in `rust/tests/fixtures/maintainer-contracts/oracle.json` were
  re-pinned to `84ff8d3ea70a2df062a8e3ac995cc0be9670c4b709e6d2c03489a630126bbc54`.

## Local targeted checks

See the PR description at push time.
