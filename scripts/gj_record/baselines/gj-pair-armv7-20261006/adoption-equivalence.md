# ARMv7 paired fixture replacement

This increment selects exact replacement bytes for a fresh macOS/Windows pair
because the historical HAP and rollback file were not found in the recorded
search scope. Historical records and all acceptance conditions remain unchanged.
The manifest records preparation facts; adoption requires maintainer review and
protected-main publication, and paired acceptance requires both actual runs.

| Material | SHA-256 | Bytes |
| --- | --- | ---: |
| Signed HAP | `ec5ce24958a16047c784a4af0f2197db86009abe1a3fbb193363a8bdd825e4bf` | 130336 |
| Signed forward library | `078b569e5cf94ac9c58d505b47f0ccece056c08c80ed8d67bb473f2ec8861f2a` | 26401 |
| Signed rollback ghost | `01d4e785ceec23a3873f67b4ec5035c0bfa469139596f88bfb96dd91dae840ae` | 26401 |

[manifest.json](manifest.json) records measured identities, Build IDs, signature
provenance, twenty source hashes and historical pins. Included sources make the
normal startup and fault mechanism reviewable. Payloads/profiles stay local,
with no keys, certificates, Raw or Runtime state in Git. Both hosts must use the
same final signed bytes without rebuilding or signing again. Real SDK verification
succeeded for both standalone libraries; it does not establish board trust.

GJ-2 retains install/package readback, Ability/process readback, HiLog/UI/Trace,
stop/uninstall/staging cleanup and typed service restart/durable reads. Startup
imports the genuine ARMv7 NAPI module and calls marker() and add(19,23). Eight
stable UI rows and marker/check text supply observable content. Baseline and
forward preserve the same API/result42, with distinct markers and Build IDs.
This is behavior equivalence, not byte equivalence with the lost historical HAP.
The packaged baseline has no standalone footer; codeSign:null stays explicit.

The ghost adds DT_NEEDED:libarkdeck_ghost.so to the same ARMv7 module. Its stub is
link-only and must never be packaged or installed. This preserves the historical
fault mechanism: admission/staging/atomic publication followed by loader failure
when the dependency is absent. Pre-admission rejection is not rollback evidence.
Runtime must automatically restore the actual prior whole library hash, restart
the app, verify loading again and leave zero outstanding residue on each host.

record.py selects only the new exact ghost digest. Assembly has no digest override.
Old hashes remain in historical records and the manifest. After maintainer review
and publication, local GJ-2/GJ-3 consumers select this manifest's HAP pin. The old
forward hash remains comparison metadata. Catalog/contracts/authority/recovery
and accepted loader/publish/rollback predicates are unchanged.

Matching profile/certificate/Java/JAR digests and SDK signatures do not waive
actual device trust, loaded ABI, process maps, post-publication failure or the
macOS/Windows pair. appIdentifierPresent:false remains explicit.
