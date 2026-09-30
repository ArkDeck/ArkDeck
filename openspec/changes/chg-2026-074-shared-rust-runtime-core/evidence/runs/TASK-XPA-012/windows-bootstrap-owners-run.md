# TASK-XPA-012 — the Bootstrap registry owners on the Windows daemon (`runtime.bundle.*`, `runtime.tool.*`)

Change: CHG-2026-074-shared-rust-runtime-core. Windows phase, parity slice G2-B (part A). Base:
protected `main` `8006b905` (#2422). Host: the Windows 11 x64 reference host, non-elevated, NTFS.
No device was contacted and no `hdc` ran. The host's DevEco Studio
(`C:\Program Files\Huawei\DevEco Studio`) was read, never run or written, by the opt-in live
checks named below. Host tests are not Windows acceptance.

Basis: maintainer ruling 17 (the daemon's signer or publisher identity) and the maintainer's
delegation of 2026-09-30 (non-major choices follow the agent's recommendation, as rulings 18-28
record); the delegated minor decisions below. This part composes the owners and serves
everything whose Windows form exists. HDC registration stays refused until a Windows HDC tuple is
registered (CHG-2026-078), and so does `runtime.tool.select`; daemon Bundle registration is
refused until a Windows daemon-bundle form exists (below).

## The gap

The Windows census (`windows-remaining.md`) listed `runtime.bundle.*` (4) and `runtime.tool.*`
(5) with no owner. Everything behind them was macOS-only:
- `arkdeck-bootstrap`'s store, bundle and tool registry owners, retirement, references and the
  HDC selection ledger;
- `arkdeck-hoststore`'s paged inventories and DevEco retirement;
- the daemon's `BootstrapReaders`.

The DevEco registry itself had been built on Windows by #2412, with no daemon owner and no
retirement.

## What was built

- **`arkdeck-bootstrap` on Windows.**
  - Built on Windows: the store's lock protocol, the frozen index read, list, inspect and
    retirement, the bundle references and the selection ledger. They run over the NTFS host
    store (`HostDirectory`, `HostReadLock`, document publication), which already had every
    primitive they use.
  - macOS-only: the native content readers (Mach-O, the bundle signature, the tree walker and the
    tool capture) and `create_store` (the CLI's zero-Runtime install).
  - On Windows, a retained HDC's content check and the daemon-bundle policy refuse
    (`PermissionDenied`). So any record present is refused as failing its native trust policy.
    Registration refuses before the store is locked: an HDC `admissionDenied` (no Windows HDC
    tuple is registered, CHG-2026-078), a daemon Bundle `operationUnavailable` (the Windows
    daemon is installed as the signed package).
  - The published HDC identities table is macOS's `published_identity`. It is not used on Windows,
    whose counterpart answers none.
- **`arkdeck-hoststore`.** The paged bundle and tool inventories and DevEco retirement are built
  on Windows. A workspace preset's toolchain pin stays macOS-only, because the workspace
  composition that takes it is macOS-only.
  - DevEco retirement encodes the index as its registration encodes it (`serde_json::to_vec`),
    not in canonical JSON. An NTFS file id in a Windows root or child identity can exceed the
    exact integer range canonical JSON admits: the live retirement failed with
    `IntegerBeyondExactRange`, `recordUnreadable`, until this change. macOS keeps the canonical
    form, byte for byte.
- **The daemon.** `windows_lifecycle::Authority::compose` opens the Bootstrap root:
  - a development root's private `bootstrap`, the macOS isolated owner's name;
  - the account's `%LOCALAPPDATA%\ArkDeck\Bootstrap\v1`, created owner-only at the start.

  It composes `BootstrapReaders` over that root. `Host::owner_census` names `bootstrap` after
  `workspaceProjects`, the macOS order, and every Windows census assertion moved with it.
  `runtime.tool.select` answers Swift's no-owner refusal (`operationUnavailable` "the Runtime
  tool-selection owner is unavailable"). The other control-action methods keep the foundation's
  refusal.
- **Paths.** The control layer and the CLI take a registration path as the host spells an
  absolute one: `/…` on macOS, unchanged, and a drive path `X:\…` without `.`/`..` on Windows.
  The owner then checks the path strictly. The CLI expects the host's `platform` in a returned
  record.
- **Contract (generators only).**
  - A Windows DevEco child tool's Authenticode trust has no team, so `teamIdentifier` is null.
    The four `runtime.tool.*` result schemas required a string there, and the control layer
    replaced a Windows registration's receipt with `outcomeUnknown`.
  - `generate-control-contract.py` gains a `SHARED_MEMBERS` entry. It lends the tool trust's
    recorded `teamIdentifier` samples (null for an unsigned HDC, one Swift member) to
    `childTools[].trust.teamIdentifier`.
  - It also gains `TOOL_INSPECT_OWNER_ERROR_CODES`, so that a derivation over the committed
    corpus keeps `runtime.tool.inspect`'s owner codes, which the first recording had published.
  - The four methods were derived over their committed corpora alone. The corpus files are left
    as committed, and `x-arkdeck-sampleCounts` moves to their counts, as in #2370/#2382. The
    only other schema change is the widening.
  - Then `generate-contract --write` and `generate-clientkit --write`, LF. The contract identity
    is unchanged.
  - macOS effect: none; a macOS child trust always names its team.
- **Coverage.**
  - `bundle` and `tool` leave `MACOS_ONLY_RUNTIME_GROUPS` (ruling 10's Windows counterpart, as
    #2411 does for `service`).
  - Measured and added to `WINDOWS_MEASURED_LEAVES`: `runtime.bundle.list`,
    `runtime.tool.list|inspect|remove`.
  - `cli-feature-coverage.json` was regenerated with `arkdeck maintainer contracts export`:
    Windows `implemented` 62 → 68, `partial` 78 → 81, unset 116 → 107, over `main` with #2425.
  - The six oracle pins of its digest were substituted
    (`b5ada317…` → `b81ebc47…`).

## Delegated minor decisions (pending the next rulings batch)

1. **The account's Bootstrap registry is `%LOCALAPPDATA%\ArkDeck\Bootstrap\v1`.** This is the
   macOS relative name below the product directory, as the Sessions and Trace locations decision
   placed theirs (`runs/TASK-XPA-005/windows-account-locations-run.md`). A development root keeps
   `bootstrap`.
2. **Registering an HDC is `admissionDenied` until a Windows HDC tuple is registered
   (CHG-2026-078), a daemon Bundle `operationUnavailable` until a Windows daemon-bundle form
   exists, and `runtime.tool.select` gives Swift's no-owner answer.** Each is refused before the
   store is locked, and nothing is written.
3. **The contract widening above**, through the generator's shared-member rule rather than a
   Windows-recorded frame in the Swift corpus.
4. **DevEco retirement's Windows index encoding** (above).
5. **Measured leaves.** Only leaves whose success path a Windows run exercises are counted:
   - `runtime.bundle.list` (the empty page);
   - `runtime.tool.list|inspect|remove` (the host's DevEco toolchain).

   `runtime.bundle.inspect|remove|register`, `runtime.tool.register` (its `--kind hdc`) and
   `runtime.tool.select` stay `partial`.

## Tests on Windows

- **`arkdeck-agentd/tests/windows_bootstrap_owners_process.rs`** (new).
  - Over the pipe of the real daemon on a development root:
    - Swift's recorded answers for an empty registry are replayed byte for byte (the snapshot
      revision aside): the empty bundle and tool pages, `pageSize` 0, an invalid tool to remove,
      a relative HDC, and `runtime.tool.select` with no owner.
    - Each refusal has zero dispatch and writes nothing: a Bundle or HDC registration, a macOS
      path, and absent bundle, tool and toolchain references.
    - The first paged list publishes the empty indexes under `.lock`.
    - All of it again after a restart.
  - Through the real CLI against a copy of the daemon signed by the development signer:
    - the bundle and tool pages, and the absent-reference, registration and selection refusals;
    - with `ARKDECK_LIVE_DEVECO_ROOT`, the host's DevEco Studio registered
      (`toolchain:sha256:7518795c…`, `platform: windows`);
    - re-registration, inspection and listing equal to it, and inspection after a restart;
    - retirement to generation 2, `removed`, read back after another restart, and
      re-registration from the same root refused `resourceConflict`.

    Each asserts that what it measured is `implemented` in the rendered coverage.
- **`arkdeck-hoststore` `windows_registration_tests`.**
  - New: a fixture toolchain retires once, a retry answers the same receipt and writes nothing,
    and the absent and wrong-generation refusals.
  - The live test now also validates the installed DevEco Studio's record against the published
    `runtime.tool.register` and `runtime.tool.inspect` schemas. Before the widening it failed on
    `childTools[2].trust.teamIdentifier: null`.
- **`windows_method_conformance_process.rs`.** No reply of the nine methods is replaced as
  non-conforming.
- **Census** (`rust/scripts/windows-method-census.py`, before the merge of #2425 and #2426): 78 methods answered by a composed owner
  (11 results, 67 owner refusals), 25 with no owner, and 2 whose recorded requests are malformed
  on Windows. Those two are `runtime.bundle.register` and `runtime.tool.register`: every
  corpus request names a macOS path, which the process test replaces with a Windows one. The
  dashboard (`windows-remaining.md`) is refreshed per milestone in its own commit, so it is not
  changed here.

## The next part

1. **HDC registration machinery on Windows**: `hdc.exe` with its sibling `libusb_shared.dll`, the
   tree walker and capture on NTFS, PE in place of the Mach-O check, Authenticode in place of
   codesign, admitting only an executable a registered Windows HDC tuple names (#2426's
   `WINDOWS_HDC_TUPLES`, empty until CHG-2026-078 registers one, so registration still refuses).
2. **A Windows daemon-bundle form** for `runtime.bundle.register|inspect|remove`: the RC xcopy
   tree verified against its `rc-manifest.json` and the signer or publisher pin (ruling 17).
3. The tool-selection owner is S1's, over this registry.

## Local checks

With `CARGO_TARGET_DIR=D:\cargo-target\g2-bundle` and `ARKDECK_DEV_SIGNER_THUMBPRINT` set:

| command | result |
| --- | --- |
| `cargo fmt --all --check` | pass |
| `cargo clippy --workspace --all-targets -- -D warnings` | pass |
| macOS cross-check: `cargo clippy --target aarch64-apple-darwin --workspace --all-targets -- -D warnings` (xcrun, ar and cc stubbed) | pass |
| `cargo test --no-fail-fast -p arkdeck-bootstrap -p arkdeck-hoststore -p arkdeck-control -p arkdeck-cli -p arkdeck-agentd -p arkdeck-contract` (with `ARKDECK_LIVE_DEVECO_ROOT`) | pass, 0 `SKIPPED` lines, once the CLI and control tests that replay macOS records and paths were made host-aware (a replayed record names this host's platform on Windows, and a registration path is an `X:\…` one there; macOS asserts exactly what it did) |
| the Bootstrap process test and the Windows DevEco tests with `TEMP`/`TMP` on an 8.3 short path on C: | pass |
| `dotnet test ClientKit.Tests` (the regenerated schema hashes) | 41 passed, 2 skipped (their own environment-gated skips) |
| `generate-control-contract.py --check`, `generate-contract.py --check`, `generate-clientkit.py --check`, `refresh-contract-digests.py --check` | pass |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`, `git diff --check` | pass |
