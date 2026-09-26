# TASK-XPA-018 — SDK release signing installation

Local implementation in progress. `runtime signing install-sdk-release` and
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
to modify source material. A failed preparation removes its new managed attempt;
success retires only a validated previous immediate-child managed directory.
Unknown receipt publication keeps the credential owner guarded, so a receipt
whose failed attempt was cleaned cannot be admitted by automatic recovery.

## Planned verification and limits

Five integration fixtures cover successful replacement, signer/verification
failure, active preset pins, malformed template/chain, and preservation of a
previous installed credential after failed replacement. Four profile unit tests
cover bundle/validity generation, closed template/name shape, chain construction
and exact verification readback. The process stand-in is the same vendored Swift
fixture used by existing signing tests; secrets are in memory. These are not
real cryptographic or device acceptance.

The Swift pre-Keychain relative-path recording script is prepared. Recordings,
Rust tests, Clippy and final SDD checks have not yet run: the coordinator has
reserved the host for TASK-XPA-025 formal performance measurement. This note
will record the commands, exits and logs after the next test window.

## CI

No PR yet. Direct current-thread authorization for remote publication remains
pending after automatic approval rejected cross-thread authorization. No
alternate push path is used. Identity refresh and the corrected install/DevEco
stack remain local dependencies; no known-bad installation head is submitted
separately for merge.
