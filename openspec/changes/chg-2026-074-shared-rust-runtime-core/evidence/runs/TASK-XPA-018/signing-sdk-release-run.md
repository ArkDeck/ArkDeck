# TASK-XPA-018 — SDK release signing installation

Local implementation and targeted verification complete; independent review
and remote CI/maintainer approval remain. `runtime signing install-sdk-release` and
legacy `signing install-sdk-release` use explicit SDK, Java, bundle name and
optional project reference inputs. No SDK search, download, real credential or
device operation has been performed while developing this slice.

## Implementation

The credential owner holds its existing guarded replacement lock while it
builds the managed material. Active workspace preset pins refuse before any
material preparation. The installer measures the SDK JAR, public keystore,
profile certificate and release template, writes a private `sdk-release-UUID`
directory and generates a bundle-bound release profile with fresh validity.
It requires the accepted release/template fields and constructs the application
certificate chain from the measured root/CA plus the template's application leaf.

Java runs through its verified executable identity, with the JAR retained by
inode. Generated inputs remain held as verified sources. Two SDK public-password
prompts use the existing bounded PTY; no password travels through argv. Exact
`verify-profile` readback must confirm the bundle, validity and release form
without debug-info. Only then does the shared installer publish the receipt and
envelope using the pending-account/unknown-publication guard.

The new profile's permissions are changed through its retained, owned,
single-link file descriptor. This does not follow a signer-produced path link
to modify source material.

## Material-publication review correction

Review of initial local candidate `ead6fa5910d96c213c15dfdda7accf0e6785f05e`
found its unconditional attempt destructor could remove files already named by
an installed receipt when receipt publication or the final owner-ledger write
failed. That candidate is not a mergeable head.

The corrected transaction durably tracks bounded `pendingMaterialDirectories`
alongside pending accounts. References must be exact `sdk-release-UUID`
immediate children of the canonical signing root; outside paths refuse before
mutation. Both new material and the prior managed material are tracked before
receipt replacement. Before any receipt publication attempt, directory cleanup
ownership moves from the local destructor to this ledger tracking. It is not
implemented with `mem::forget` or an untracked orphan directory.

A preparation failure can clean an unreferenced attempt after proving the
installed receipt remains safe. Once receipt publication is attempted, the
new material remains available for explicit recovery. After validating the new
receipt, retirement excludes its current managed directory and refuses to
remove any other tracked directory still referenced by its pinned files.
Explicit install/rekey repair and removal retire the tracked leftovers without
widening cleanup outside the private root. Successful stable ledgers omit the
pending fields as before.

Ledger writes preserve `BeforePublication` versus `OutcomeUnknown`. A final
stable write that fails before publication leaves the prior durable guard.
After an unknown outcome, only a successful synchronized guard write establishes
that quarantine has been restored. If that restoration also fails, the command
reports both outcomes uncertain; it does not claim the guard is durable or
delete the retained material. The original durable tracking and the receipt
that actually landed remain the recovery evidence. No persistence guarantee is
claimed for a filesystem that cannot synchronize either record.

Fault fixtures cover receipt-publication uncertainty and the final stable-ledger
write failing both before publication and after rename. They check retained
receipt-referenced files, refusal by current/restarted owners when the guard is
proved present, and complete explicit repair/removal cleanup. The publication
unit fixture substitutes material preparation only; the separate integration
fixtures actually run the vendored signer/verification process.

## Local targeted checks and limits

Five integration fixtures cover successful replacement, signer/verification
failure, active preset pins, malformed template/chain, and preservation of a
previous installed credential after failed replacement. Four profile unit tests
cover bundle/validity generation, closed template/name shape, chain construction
and exact verification readback. The process stand-in is the same vendored Swift
fixture used by existing signing tests; secrets are in memory. These are not
real cryptographic or device acceptance.

Corrected code head: `aa3bd266f09eeb187e6dd9b3c68994f69557d942`.
Rust commands use `CARGO_TARGET_DIR=/private/tmp/arkdeck-takeover-d79c-target`
and `CARGO_BUILD_JOBS=2`.

- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-provider-workspace`:
  exit 0, 54 pass. `/private/tmp/arkdeck-signing-sdk-final-provider.log`.
  This includes the two added material-publication/cleanup unit tests, the
  five actual fake-signer SDK process fixtures and existing installation,
  DevEco and signing regressions. The pre-existing fake HAP signer uses
  disposable file Keychains; SDK tests use memory secrets only.
- Initial corrected SDK fault run (`--lib --test sdk_release --test signing_install`)
  exited 101: cleanup exposed the Foundation `/tmp` spelling versus the
  physical path required by `HostDirectory::open`. The fix preserves only
  physical-canonical or Foundation-canonical root spellings; arbitrary symlink
  spellings still refuse. `/private/tmp/arkdeck-signing-sdk-fixed-provider.log`.
  The same targeted command then passed 38 tests (exit 0), followed by the
  final full provider suite above. `/private/tmp/arkdeck-signing-sdk-fixed-provider-2.log`.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli --test argv_fixtures
  --test signing_install --test signing_remove --test signing_refresh
  --test signing_status`: exit 0, 29 pass.
  `/private/tmp/arkdeck-signing-sdk-cli.log`.
- Twelve real Swift SDK/Java relative-path refusals were recorded with
  `rust/scripts/record-signing-sdk-oracle.py` and replayed byte-for-byte across
  both spellings and three output modes. Every process refuses before owner
  mutation or Keychain item access and leaves its temporary home unchanged.
  Fixture provenance names the actual Swift binary digest; HOME is not used as
  Keychain isolation. `/private/tmp/arkdeck-signing-sdk-oracle-20260926`.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-provider-workspace
  -p arkdeck-hoststore -p arkdeck-cli --all-targets -- -D warnings`: exit 0.
  `/private/tmp/arkdeck-signing-sdk-final-clippy.log`. Initial Clippy exited
  101 for `collapsible_if`; the condition was collapsed without suppressing
  the warning (`/private/tmp/arkdeck-signing-sdk-clippy.log`).
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`, `git diff --check`,
  and `sh scripts/check-sdd.sh`: exit 0, 121 acceptance IDs.
  `/private/tmp/arkdeck-signing-sdk-sdd.log`.
- `python3 rust/scripts/generate-contract.py --check`: exit 0, 105 methods,
  1,043 shapes. `/private/tmp/arkdeck-signing-sdk-contract.log`.

No full local unified gate, App build, real SDK signer, installed credential,
login/Data Protection item, launchd service or device was changed. Full
hoststore/CLI suites were not repeated in this coordinated window; signing
behavior was targeted and their targets compiled by Clippy. These results do
not constitute real cryptographic/Keychain/GJ-5 acceptance or G5 completion.

## CI

No PR yet. Direct current-thread authorization for remote publication remains
pending after automatic approval rejected cross-thread authorization. No
alternate push path is used. Identity refresh and the corrected install/DevEco
stack remain local dependencies; no known-bad installation head is submitted
separately for merge.
