# GJ-3 on 7.0.0.37 — why the kernel refuses the signature (2026-08-06)

## Status: still `FAIL`, but the cause is measured, and the cause we recorded yesterday was wrong

`deploy.native-library.app-owned@1` fails at `atomic-publish` with
`nativePublishMismatch`. The [GJ-4 evidence](gj4-flash-any-build-2026-08-06.md) recorded this as
"a firmware behaviour change, not a regression in this work". The first half of that is false and
this document replaces it.

- Baseline: `main@1b6f0bff`
- Catalog digest: `e2f8eb6592aaeeec37c63a01708db2325b38c798b0f8272228ba0fccc2cfd0aa` (unmoved)
- Target: `TGT-958780b2ffb7`, binding revision `2`, firmware `OpenHarmony-7.0.0.37`
- Failing job: `job-eabc672b1937cc724b8179015d1e9d3c`

## The number the old diagnostic reported was not the kernel's

The helper read `errno` at the reporting site, after `free`, `close` and `unlink` had run. The
`errno=129` in yesterday's record was therefore not evidence of anything. That is fixed
separately; every failure path now records at the point of failure.

With the fix in place, and the daemon rebuilt so it actually ships the rebuilt helper
(`sha256=610d167d…`), the same run reports **`errno=129` again** — this time meaning it.
`129` is `EKEYREJECTED`, read out of the OHOS toolchain's own `errno.h`, not from memory.

## What the kernel says when asked directly

Reproduced on a scratch copy under `/data/local/tmp`, with the kernel log captured across the
`FS_IOC_ENABLE_CODE_SIGN` call:

```
fs-verity: [I/code_sign_kernel]code_sign_verify_certchain: developer mode on
fs-verity: [I/code_sign_kernel]pkcs7_find_key: sinfo->index 1
[E/code_sign_kernel]matched_cert_search: cert not found          (×4)
fs-verity: [E/code_sign_kernel]code_sign_verify_certchain: cert subject and issuer verify failed
fs-verity (mmcblk0p15, inode 2794): verify cert chain failed, err = -129
```

The feature is present, active, and in developer mode. It parsed our PKCS#7 and refused the
certificate. The GJ-3 fixture library is signed by a leaf we minted for the journey:

```
subject = C=CN, O=OpenHarmony, OU=OpenHarmony Team, CN=ArkDeck GJ3 App
issuer  = C=CN, O=OpenHarmony, OU=OpenHarmony Team, CN=OpenHarmony Application CA
```

The device matches `(subject, issuer)` pairs against
`/system/etc/security/trusted_cert_path.json`. Under that issuer it accepts exactly two subjects:
`OpenHarmony Application Release` and `ide_demo_app`. `ArkDeck GJ3 App` is not one of them, and no
wildcard covers it.

## The firmware did not take anything away — it added

`trusted_cert_path.json` from the 7.0.0.35 archive, compared against the running 7.0.0.37:

| | 7.0.0.35 | 7.0.0.37 |
|---|---|---|
| `trust-profile-path` rows | 5 | 5 |
| `trust-cert-path` rows | 12 | **14** |

The difference is two rows, both **added** in `.37`, both for the `OpenHarmony Application CA`
issuer — the two subjects listed above. Nothing was removed. Neither build has ever had a row that
would admit the GJ-3 leaf.

So "the same library passed on 7.0.0.36 hours earlier" cannot be explained by a firmware
tightening, because there was none. **What made that run pass is not established.** The device has
since been flashed, so its prior state cannot be re-examined, and 7.0.0.36 is not among the
archives on this host (`.33`, `.35`, `.37`). It is recorded here as an open discrepancy rather
than explained away; the honest reading is that the earlier `PASS` needs re-earning, not that it
was contradicted.

## Signing with a subject the device does trust moves the wall, it does not remove it

The candidate was re-signed with the SDK's stock identity — leaf
`CN=OpenHarmony Application Release` issued by `OpenHarmony Application CA`, in the appended
`elf sign block  1000` container the helper parses (`hap-sign-tool sign-app -inForm elf
-signCode 1`; the current `binary-sign-tool` writes a `.codesign` **section** instead, which the
helper does not read, and that is a separate gap). The kernel then says:

```
[I/code_sign_kernel]matched_cert_search: cert found
fs-verity: [I/code_sign_kernel]code_sign_verify_certchain: cert subject and issuer trusted
fs-verity (mmcblk0p15, inode 3318): File's signing cert isn't in the fs-verity keyring
```

`errno=126`, `ENOKEY`. Cert-path matching now succeeds; the signing certificate still has to chain
to a key already in the kernel's `.fs-verity` keyring. That keyring holds four keys:

```
fs_verity_key0 / key1 / key2   X509.ecdsa-nist-p384      (vendor)
local_key                      X509.ecdsa-nist-p256      (generated on the device)
```

No chain we can mint on the host reaches any of them. The only non-vendor key is `local_key`,
which the platform's own local code-sign service holds.

## The property the operation demands, the platform does not apply

Measured on this device with the same helper:

| file | `FS_IOC_MEASURE_VERITY` |
|---|---|
| `…/com.example.scrollablecomponentstatic/libs/arm/libarkdeck_gj.so` (installer-placed) | `ENODATA` |
| `…/libs/arm/libc++_shared.so` (installer-placed) | `ENODATA` |
| `/system/lib/ld-musl-arm.so.1` | `EOPNOTSUPP` (partition has no fs-verity) |

The installer does not put fs-verity on app-owned native libraries on this build. So
`deploy.native-library.app-owned@1` is currently refusing to publish a library unless it carries a
property that the platform's own installer does not give the file it replaces.

That is the finding worth acting on. The operation's verification is not wrong to want an
attestable file; it is wrong to require one the device cannot be persuaded to produce from a
host-side signature. Two shapes of fix are visible, and choosing between them is a design call,
not something to settle inside a device window:

1. Obtain the signature from the device's local code-sign service, so the enabling key is
   `local_key` and already in the keyring.
2. Make the fs-verity readback conditional on the platform applying it at all — verified when the
   file it replaces carried verity, and hash-and-ownership only when it did not.

## What the product did right, and what it did not

Right: it failed closed at the step it could not verify, captured the subprocess diagnostics that
name the cause, ran its compensation, and left the app's live library untouched. The publish
sequence — copy beside the target, enable, read back, and only then rename — is why a refused
enable cannot replace a working library. All of that held.

Not right: the diagnostic it captured was reporting the cleanup's `errno`, so the one number that
distinguishes the two very different causes above was noise for a full day. Fixed under the same
task.

## Reproduction

Device probes were run as scratch copies under `/data/local/tmp` and removed afterwards; nothing
in the app's own directories was mutated outside the product's own compensated run.
