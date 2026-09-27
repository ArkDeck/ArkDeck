# Applied SHA backend dependency policy — TASK-XPA-025

Status: applied after the coordinating task's independent review; compiled
compatible-lock KAT/integrity checks pass; PR CI/review remain pending. The user authorized
macOS implementation and PR push/merge work. This record does not claim separate
per-package user approval or a complete source audit by a human maintainer.

The review inspected the exact package manifests/build script/wrapper, the sha2
ARM selection and fallback, and the registry/archive/lock identity. The approved
change is one `trusted.sha2-asm` rule: `safe-to-deploy`, user 5059, start
2024-05-07, end 2024-05-08. The half-open interval covers one UTC publication day,
not future releases. `deny.toml` additionally requires exactly 0.6.4 and Cargo.lock
requires checksum `b845214d6175804686b2bd482bcffe96651bb2d1200742b712003504a2dac1ab`.
No other trust, exemption, audit certification, import source or future window
was added; prior trust semantics were compared and proved unchanged.

## Identity and use

The [crates.io version response](https://crates.io/api/v1/crates/sha2-asm/0.6.4)
was checked on 2026-09-27: publisher 5059/newpavlov (Artyom Pavlov), publication
2024-05-07T16:24:37.057435Z, declared MIT, not yanked at that check. Registry,
Cargo.lock and cached .crate SHA-256 agree; inspected files match that archive.
Raw registry/source identities and five-source query facts are adjacent.

sha2 0.10.9's `asm` feature includes sha2-asm, whose build.rs invokes the host
compiler/archiver on fixed crate assembly sources. macOS ARM selects the Apple
AArch64 source with `-march=armv8-a+crypto`. This is build-time executable code,
not passive metadata. The ARM runtime path uses sha2's own intrinsics/inline asm,
CPU feature detection and software fallback; its x86 branch contains the external
sha2_asm call. No linker dead-code/exclusion claim is used to exempt the dependency.
Windows must remain excluded by the macOS/aarch64 target feature condition.

Publisher checks do not prove absence of source defects or account compromise.
The review is not a proof of every assembly instruction/ABI/cryptographic round.
Exact source pinning, deny advisory/license/source checks, known-answer tests,
mutation/range refusal tests and final native CI are separate evidence. Full-file
hashing and all existing descriptor/path identity checks remain unchanged.

## Minimized graph and actual imported audits

The initial experiment graph used cc 1.4.5, find-msvc-tools 0.1.12 and shlex 2.0.1.
The final compatible graph retains sha2-asm 0.6.4, selects cc 1.2.5 and shlex 1.3.0,
and removes find-msvc-tools. sha2-asm requires `cc = "1.0"`; this selection satisfies
that requirement. Runtime hash source/algorithm is unchanged, but new build-tool
pins are not retroactively attributed to the earlier binary results.

Only existing imported source assertions supply cc/shlex coverage:

- cc: Bytecode full 1.0.73 → Mozilla 1.0.78 → Mozilla 1.0.83 → Bytecode 1.1.6 → Bytecode 1.2.5.
- shlex: Bytecode full 1.1.0 → Mozilla 1.3.0.

Pinned audit references are [Bytecode Alliance](https://github.com/bytecodealliance/wasmtime/blob/f543666f4c59adbc8d22eabb975215fb78595b61/supply-chain/audits.toml)
and [Mozilla](https://github.com/mozilla/supply-chain/blob/d7f9f897cbabc04d16ae2a62374e098d850d46fa/audits.toml).
The configured five sources contain no sha2-asm source-audit chain; that precise
remaining gap is why the independently reviewed publisher rule is explicit.

## Validation and failure history

Initial deny failed the four new exact-version entries; initial vet failed all
four packages. Explicit allow entries made deny pass. A normal five-source import
refresh supplied shlex 2.0.1's existing chain; vet still failed three. The compatible
cc/shlex pins and real imports reduced vet failure to sha2-asm alone. No failure
was suppressed or classified as an invalid run.

After the coordinating review the single rule was applied through normal tool
approval. Vet first rejected only alphabetical formatting of the appended entry;
reordering that exact entry and regenerating imports added its matching publisher
metadata. `cargo vet --locked --no-registry-suggestions` and `cargo deny --locked
check` then returned 0. All stages are archived. The successful vet label reflects
the configured audit/publisher policy, not complete source-audit coverage.

The local compatible-lock SHA known-answer and Artifact mutation/replacement
refusal checks each passed (one test, exit 0); logs are adjacent. The additional
hoststore owner repeat was deferred when the coordinator reclaimed the window
for a Runtime fix; the earlier full targeted run includes those owner tests. Final PR CI validates the full graph
and native targets. No baseline adoption or G5 completion follows from this policy.
