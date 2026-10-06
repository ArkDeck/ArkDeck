# Exact trace transport representation — proposed scoped delta

Source: protected main `04d9e028be5f80b6d0a68dfffed69998bdcf0575`.
This is one implementation-and-review increment for the existing trace probe,
not an approval, hardware declaration or completed Golden Journey.

The Windows Runtime's bounded `trace.probe` returns the registered hitrace help
with homogeneous CRLF line endings. Root verified its immutable captured CLI-envelope
SHA and, in memory only, verified that replacing each CRLF by LF reproduces the
existing registered suffix byte for byte. Help is 3,428 bytes and 46 CRLF pairs;
the LF spelling is 3,382 bytes. The raw suffix SHA-256 is
`cbba18918a3418167656b3bd68d40d86b187d436d9c690bc912c56e0a94fc51d`;
the LF suffix remains
`b40edec78a823762d64599b21c4fd2c82be4a9071e0457120a6e6526433ed3f8`.
Root independently verified hitrace tags (3,687 bytes / 83 CRLF pairs) and the
bytrace help/tag representations with the same strict byte-equality procedure.
All four diagnostics returned exit 0 with empty stderr and no bare CR/LF.
The separately pinned descriptor records their exact whole/suffix hashes and
the existing LF fingerprints. Provenance is `repoReadOnlyDiagnostic`, with
`formalAcceptance=false` and `hardwarePass=false`, not controlled human
capture or formal Runtime evidence.

## Before and after

Before this delta, the exact registered LF help and tag list select
`hitrace.dayu200-oh7.text`; their CRLF transport spelling is unsupported.
After maintainer review and protected-main publication, the shared provider may
also recognize the separately pinned CRLF spelling of each same family, only
when both help and tag-list representations have verified provenance and the
complete predicates below hold. This introduces no tool, family, command,
flag, tag, timeout, cleanup, capture marker or capture-success authority.

1. Preserve every byte and hash of `OPENHARMONY-TRACE-PROBES@1.0.0`, its resource
   manifest and all seven original resources. The original LF verdicts and
   recorded Swift-oracle outputs remain unchanged.
2. Pin a separate representation descriptor. Its only new accepted form is
   hitrace/bytrace help/tag stdout with the exact declared raw byte length and suffix
   SHA-256 after the existing valid timestamp prefix.
3. Require homogeneous CRLF throughout the complete output. Bare CR, bare LF,
   mixed endings, duplicate CR, truncation, trailing bytes, different text,
   invalid timestamp, nonempty stderr or a wrong tool must remain unsupported.
   No arbitrary CR removal, whitespace trimming, Unicode normalization, ANSI
   stripping or marker-only comparison is permitted.
4. Convert only the validated representation in temporary memory for
   comparison, then require its exact existing LF length and suffix SHA-256.
   Tag parsing produces exactly the original 81 tags. Persisted raw receipts,
   `rawHelp`, `rawHelpSha256` and tool raw-help hashes retain the original
   transport bytes. Normalized bytes never replace raw evidence.
5. Bytrace's original LF and newly observed CRLF spellings remain probe-only.
   Hitrace help alone cannot select capture without its own exact tag-list receipt.
6. Retain current HDC native identity, registered platform tuple, selected
   endpoint, durable target/binding, parameter catalog and every Runtime
   capability/effect/Journal/owned-path/cancellation/unknown-result guard.
   This descriptor cannot borrow a macOS HDC tuple or mint Windows identity.
7. Bump only the current OpenHarmony integration/profile lock to record this
   additive representation adoption. Existing registries retain their original
   profile versions and hashes. Catalog, Core requirements, schemas and control
   pins do not change.

## One layer and its consumers

The implementation is confined to provider-hdc trace-family selection and its
pure tests, a separately pinned integration representation descriptor, current
profile/lock references, corresponding Rust/Swift closure assertions and this
change-local delta/run note. There is no retired Swift provider to revive: the
current Swift client consumes the unchanged typed trace projection. Its
contract test checks descriptor/golden/profile/hash closure; the existing
ControlFrames and LF oracle remain byte-for-byte unchanged.

Compatibility: the historical trace pack's timestamp-only policy stays intact;
this reviewed additive descriptor names the sole extra transport
representation explicitly. `PRODUCT-LOOP.md` permits implementing the concrete
product correction in the same reviewable increment. Existing archived trace
evidence, Task/status/ruling files, platform conformance, hardware declarations
and captured Raw are not edited.

## Verification and limits

Pure regressions must prove LF parity, the exact CRLF equivalent, original raw
bytes/hashes, all listed malformed/refusal forms, wrong-tool refusal,
and no capture selection after malformed tags. Descriptor tests must close
both normalized and raw suffix fingerprints against the original immutable
resources. Run the affected provider and direct-consumer checks on a bounded
host-only check window; use CI for the affected Swift class/macOS parity.

Root owns actual Runtime/transport use and public capture integration. The
observations are read-only diagnostics, not successful trace captures or
hardware passes. Root's exact tag equality is included in the descriptor;
maintainer review and protected-main publication precede new Runtime use.
