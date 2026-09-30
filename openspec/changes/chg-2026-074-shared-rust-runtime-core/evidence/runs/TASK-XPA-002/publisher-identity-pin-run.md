# TASK-XPA-002 — pin the production xcopy daemon by publisher identity, 2026-09-30

Implements maintainer ruling 17 (`evidence/windows-maintainer-rulings-20260930.md`,
#2351): how the Windows client pins a production-signed daemon. Host tests on the
reference Windows 11 x64 host. No Artifact Signing certificate exists for ArkDeck
yet, so the production path is proved by a pure matcher over synthetic
certificates, and the `WinVerifyTrust`-integrated path positively only for the
development signer (below). Not SPK-3, not Windows platform acceptance.

Base: `main` at `62382dd8` (#2349).

## Ruling, per form

| Form | What vouches for the image | Inputs |
| --- | --- | --- |
| MSIX daemon | Its package family (`GetPackageFamilyName` on the pipe server process), unchanged. | `ARKDECK_DAEMON_PACKAGE_FAMILY` |
| xcopy daemon, production (Azure Artifact Signing) | Publisher identity: `WinVerifyTrust` accepts the image with the existing policy (`WINTRUST_ACTION_GENERIC_VERIFY_V2`, `WTD_REVOKE_WHOLECHAIN`, `WTD_CACHE_ONLY_URL_RETRIEVAL`, `WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT`); the first signer's verified chain ends at the pinned Microsoft root; the leaf has exactly one subject `O=`, equal to the configured organisation; the leaf's EKU extension holds code signing (`1.3.6.1.5.5.7.3.3`) and the configured certificate-profile identity EKU. | `ARKDECK_DAEMON_PUBLISHER_ORGANIZATION` + `ARKDECK_DAEMON_PUBLISHER_EKU` (both or neither) |
| Development signer | The leaf certificate's DER SHA-256, unchanged. | `ARKDECK_DAEMON_SIGNER_SHA256` |

All forms keep layer 1 (pipe owner SID equals the client token owner) and layer 2
(server PID → canonical image path equal to the installed daemon, held namespace
and image handles, equal file identity, process still live). Any one configured
pin that holds admits the server; none configured refuses as before. A publisher
identity with only one of its two inputs, an empty or padded organisation, or an
EKU that is not a `1.3.6.1.4.1.311.97.<profile>` OID (or is the shared Public Trust
marker `1.3.6.1.4.1.311.97.1.0`) refuses the connection outright with zero frames,
whatever else is configured. There is no input that skips verification.

## Official sources (read 2026-09-30)

- Microsoft Learn, *Artifact Signing certificate management*
  (<https://learn.microsoft.com/en-us/azure/artifact-signing/concept-certificate-management>,
  ms.date 2026-09-24): certificates "are renewed daily and are valid for only 72
  hours"; "pinning trust to an individual certificate's public key, thumbprint, or
  other certificate attributes isn't durable"; "Artifact Signing assigns a custom
  Extended Key Usage (EKU) value to each certificate profile … The durable identity
  value is a custom EKU that has the prefix `1.3.6.1.4.1.311.97.` and is followed by
  more octet values that are unique to the certificate profile", example
  `1.3.6.1.4.1.311.97.990309390.766961637.194916062.941502583`; "All Artifact
  Signing Public Trust certificates also contain the `1.3.6.1.4.1.311.97.1.0` EKU";
  all EKUs "are provided in addition to the code signing EKU (`1.3.6.1.5.5.7.3.3`)".
  Deleting and recreating a certificate profile assigns a new EKU; the
  configuration must then change with it.
- Microsoft Learn, *Artifact Signing trust models*
  (<https://learn.microsoft.com/en-us/azure/artifact-signing/concept-trust-models>):
  "The certificates in the Public Trust model are issued from the Microsoft
  Identity Verification Root Certificate Authority 2020"; Private Trust uses a
  hierarchy that "isn't default-trusted in any root program and in Windows";
  Public Trust *test* profiles "are not publicly trusted".
- Microsoft PKI Services repository
  (<https://www.microsoft.com/pkiops/docs/repository.htm>): Microsoft Identity
  Verification Root Certificate Authority 2020, SHA-1 thumbprint
  `f40042e2e5f7e8ef8189fed15519aece42c3bfa2`, certificate at
  `https://www.microsoft.com/pkiops/certs/microsoft%20identity%20verification%20root%20certificate%20authority%202020.crt`.
- KB5022661 (<https://support.microsoft.com/en-us/servicing/azure/update/2022/12/kb5022661-windows-support-for-the-trusted-signing-formerly-azure-code-signing-program>):
  verifying Trusted (Artifact) Signing modules requires that root installed.

## The root pin

Downloaded the certificate from the repository URL above (1488 bytes, DER):
SHA-1 `f40042e2e5f7e8ef8189fed15519aece42c3bfa2` (equals the repository's
thumbprint), SHA-256 `5367f20c7ade0e2bca790915056d086b720c33c1fa2a2661acf787e3292e1270`;
subject = issuer `CN=Microsoft Identity Verification Root Certificate Authority 2020,
O=Microsoft Corporation, C=US`, RSA 4096, sha384RSA, valid 2020-04-17 to 2045-04-17.
On this host it is in `LocalMachine\AuthRoot` (read with `certutil -store AuthRoot`,
no change). The SHA-256 is the compiled constant `ARTIFACT_SIGNING_ROOT_SHA256`
(`arkdeck-platform/src/windows/publisher.rs`); the certificate itself is committed as
`src/windows/fixtures/microsoft-identity-verification-root-2020.crt`, and the test
`the_root_pin_is_the_official_certificate` checks both its SHA-1 against the
repository thumbprint and its SHA-256 against the constant.

Update path (in the constant's documentation): when Microsoft announces a new
Artifact Signing root, download it from the PKI repository, check its SHA-1
against the published thumbprint, replace the fixture and the constant, and ship a
new client. A pinned root is deliberately not configurable: a configuration input
would let whoever sets the environment choose the trust anchor.

## Implementation

- `ServerIdentity` gains `publisher_organization` and `publisher_eku`;
  `arkdeck-cli` reads them from the two new environment inputs beside the existing
  ones (documented in `rust/README.md`'s input table).
- `windows/publisher.rs`: `PublisherIdentity::from_config` (both-or-neither and
  value validation) and `chain_matches(chain, root_sha256, publisher)`, a pure
  function over the DER certificates of a chain `WinVerifyTrust` verified. It
  decodes the leaf with `CertCreateCertificateContext`, reads every subject `O=`
  from `CryptDecodeObjectEx(X509_NAME)` and the leaf's own EKU extension with
  `CertGetEnhancedKeyUsage(CERT_FIND_EXT_ONLY_ENHKEY_USAGE_FLAG)`.
- `windows/identity.rs`: `SignerPins::configured` reads the pins (partial
  publisher → error); `trusted_signer_chain` runs `WinVerifyTrust` exactly as
  before and copies the first signer's chain (leaf … root) out before closing the
  state; `verify_signature` accepts when the leaf SHA-256 equals the certificate
  pin or `chain_matches` holds for the publisher pin. `ProcessIdentity::require_server`
  reads the pins before anything else and otherwise keeps its order and messages.
- CI: the Windows *Rust workspace* job now creates the same runner-only
  development signer as the contracts job before the workspace tests, so the
  `WinVerifyTrust`-integrated unit test runs there too.

## Tests (this host)

Synthetic certificates are built in memory: an ephemeral CNG ECDSA P-256 key
(`NCryptCreatePersistedKey` with no key name, never persisted) and
`CertCreateSelfSignCertificate(CERT_CREATE_SELFSIGN_NO_KEY_INFO)` with the chosen
subject and EKU extension; the chain is `[leaf, (intermediate), root]` with the
official root DER as root. No certificate or key reached any store.

| Case | Test | Result |
| --- | --- | --- |
| Publisher match (with and without an intermediate) | `publisher::the_configured_publisher_matches` | matches |
| Wrong `O=` (other name, case, trailing dot, none, two `O=`) | `publisher::a_different_organisation_is_refused` | refused |
| Missing EKU extension; only code signing; only the Public Trust marker; different profile EKU; profile EKU without code signing | `publisher::a_missing_or_different_identity_eku_is_refused` | refused |
| Wrong root; leaf only; empty chain; the official root alone | `publisher::a_different_root_is_refused` | refused |
| Partial / malformed configuration | `publisher::partial_or_malformed_configuration_is_refused`, `identity::partial_publisher_configuration_is_refused_whatever_else_is_set`, `windows_transport::partial_publisher_identity_is_refused_before_any_frame` | refused, zero frames |
| Root constant is the official certificate | `publisher::the_root_pin_is_the_official_certificate` | holds |
| Unsigned image vs. every pin | `identity::an_unsigned_image_satisfies_no_pin` | refused |
| Development hash pin unchanged, through `WinVerifyTrust` | `identity::the_development_signer_keeps_its_certificate_pin`: a copy of `System32\whoami.exe` in a private temporary directory, signed by `windows-dev-identity.ps1 sign` with the existing host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`, `CurrentUser\Root`, created before this slice); its pin is accepted, a wrong or uppercase pin refused; a publisher identity on the same trusted chain is refused (not the Artifact Signing root); publisher beside the right pin still accepts. The copy is deleted afterwards. | as stated |
| Package family unchanged; publisher or family without proof | `windows_transport::publisher_identity_or_package_family_without_their_proof_is_refused_before_any_frame` (plus the existing transport refusals) | refused, zero frames |

The integrated test skips its signed part (and says so on stderr) when
`ARKDECK_DEV_SIGNER_THUMBPRINT` is absent; it was set for the runs below.

### A real Artifact Signing publisher through `WinVerifyTrust`

This host carries executables that their vendors signed with Artifact Signing
Public Trust, found by a read-only scan (`Get-AuthenticodeSignature`, issuer
`Microsoft ID Verified CS …`). `identity::a_real_artifact_signing_publisher_is_matched_through_winverifytrust`
(gated by `ARKDECK_PUBLISHER_SAMPLE`, `_ORGANIZATION`, `_EKU`; the file is opened
and verified, never run) accepts each with its publisher, and refuses a wrong
`O=`, a different profile EKU and a wrong certificate pin:

| Sample | Issuing CA | `O=` | Identity EKU | Result |
| --- | --- | --- | --- | --- |
| `C:\Program Files\GitHub CLI\gh.exe` | Microsoft ID Verified CS EOC CA 04 | `GitHub, Inc.` | `1.3.6.1.4.1.311.97.335068538.954251622.774763419.164527060` | pass |
| `C:\Program Files\Git\mingw64\bin\git-lfs.exe` | Microsoft ID Verified CS AOC CA 01 | `GitHub, Inc.` | same as above | pass |
| `C:\Program Files\Git\mingw64\bin\git-credential-manager.exe` | Microsoft ID Verified CS EOC CA 02 | `GitHub` | `1.3.6.1.4.1.311.97.891992264.228081715.271655073.81998895` | pass |

So the production path holds with the unchanged cache-only revocation policy on
this host, and one certificate profile's EKU is stable across different issuing
intermediates, which is why the ruling pins the root and not an intermediate.

Checks at the commit: `cargo fmt --all --check`; `cargo clippy --workspace
--all-targets -- -D warnings`; `cargo test -p arkdeck-platform -p arkdeck-client
-p arkdeck-cli -p arkdeck-agentd`; `sh scripts/check-sdd.sh`; `git diff --check` —
all passed.

## xcopy package script

`rust/scripts/windows-package-xcopy.ps1` (#2349): in production mode it derives the
publisher identity from each signed file (chain root SHA-256 equal to the CLI's
pin, one `O=`, code signing plus exactly one identity EKU other than the Public
Trust marker), requires the CLI and daemon to share it (their leaves may differ
across a renewal), records it as `signing.publisher`, puts
`ARKDECK_DAEMON_PUBLISHER_ORGANIZATION` / `ARKDECK_DAEMON_PUBLISHER_EKU` in
`daemonConfiguration`, prints them instead of a certificate hash, refuses
`-ExpectedSignerSha256`, and its smoke checks and configures them. Development mode
is unchanged. Exercised on this host by loading the script's functions: the
development certificate is refused as a production publisher, and the three
samples above yield the identities in the table. No production package was built
(no Artifact Signing account).

## The pre-launch check (#2344, merged after the first push)

#2344 merged first; this branch merged `main` and then changed `verify_installed_image`
(the check before the client starts its daemon) to read `SignerPins::configured`
before opening anything and to call `verify_signature(&file, &path, &pins)`: a
signing pin that holds (certificate or publisher identity) gives `ImagePin::Signer`;
otherwise a configured package family gives `ImagePin::PackageFamily`, proved on the
running server; otherwise the image is refused. A partial or malformed publisher
identity refuses the start whatever else is set. The CLI's `installed_identity`
(`runtime_service_windows.rs`, used by `runtime service status/verify/restart`) reads
the two publisher inputs as `runtime_endpoint` does. Test:
`daemon_start::tests::the_pre_launch_check_honours_the_publisher_identity` (partial
configurations refused and nothing launched; a malformed EKU refused; a complete
publisher identity the unsigned test image cannot prove refused and nothing launched;
with a package family beside it, the family is left to the running server).
