# TASK-XPA-014 — the bundled code-sign helper the daemon composes (macOS, 2026-09-20)

TASK-XPA-014 remains in progress. Base: protected main `486f9139` (#2090); written on
`b958ff448` (#2083) and rebased onto `486f9139` without conflict after #2085 and #2086 changed
`rust/README.md`, `agentd/src/host.rs` and `provider-hdc/src/native_library.rs` in other lines.
Host-only change to
`arkdeck-provider-hdc` and `arkdeck-agentd`: no Swift source, fixture, control schema, corpus,
Catalog, entitlement, `openspec/specs` or constitution change. No device, real HDC or installed
state was used, and nothing here is device evidence (POL-VERIFY-001, POL-MODE-001).

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining (TASK-XPA-014) |
| --- | --- | --- |
| `deploy.native-library.app-owned@1` planned, admitted and run as Swift does, replaying its oracle in process; the development mutation authority (#2078); GJ-2's fake-HDC rehearsal | The daemon composes and verifies the bundled code-sign helper, so that operation is available and planned where a helper is | GJ-3's fake rehearsal and its real-device leg (runbook §4); GJ-2's real-device leg (runbook §3); debug.hap slice F; M5 activation |

## Why

A native deployment stages the code-sign helper its composition verified. The daemon composed none,
so `HdcComposition::code_sign_helper` was always `None`: the isolated daemon listed
`deploy.native-library.app-owned@1` as `unavailable` (`provider_tool_unavailable`, "bundled arm64
OpenHarmony code-sign helper cannot be verified") and refused its plan before admission. GJ-3 could
not run there at all, on a device or on the fake, which the 2026-09-20 preflight measured:

| Before this slice, isolated daemon over the fake HDC | Answer |
| --- | --- |
| `operation list` | `availability` `unavailable`, `reasonCodes` `["provider_tool_unavailable"]`, `reasonOrigins` `["host_configuration"]` |
| `job plan` of the oracle's `deployed.plan` request | exit 65, `invalidInput`, phase `preAdmission`, "deploy.native-library.app-owned@1 is runtime unavailable: bundled arm64 OpenHarmony code-sign helper cannot be verified" |

## What changes

- `arkdeck-provider-hdc` `native_elf.rs`: `static_executable`, Swift's `isStaticExecutable` — an
  `ET_EXEC` ELF with at least one loadable segment and no interpreter.
- `native_library.rs`: `CodeSignHelper::verified(bytes, host_path)`, Swift's
  `HDCNativeCodeSignHelperArtifact.bundled()` without its resource lookup: the library validator at
  arm64, no mutable input signature, a static executable, and the facts the device actions name
  (ABI, build id, SHA-256, byte count).
- `arkdeck-agentd` `code_sign_helper.rs`, new: where the helper comes from. The resource layout
  Swift looks in, relative to this executable, because the Rust daemon ships in the same helper
  bundle the Swift daemon does: `../Resources/ArkDeckKit_ArkDeckWorkflows.bundle/…`, the bundle
  beside the executable, and the one above it. `ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER` names one for
  an isolated development root, as an explicit absolute path.
- `host.rs`: the composition carries the verified helper into every `HdcComposition`, the
  request-time one and the background Job run's, and the availability context reports it.
- `main.rs`: the bundled helper is composed for every composition; a helper that is there and does
  not verify is reported (`native deployment stays unavailable: …`) and the daemon serves without
  it, as it did before. The development variable is refused outside an isolated development root,
  as the other development variables are, and a named helper that does not verify fails startup.
- `rust/README.md`: the native deployment's paragraph, and the sentence that said the daemon
  composes none.

## What it does not change

- Without a helper the operation stays `unavailable` with the same reason code, origin and text,
  and its plan is refused with the same message.
- The facts the deployment carries are the file's own, so naming a path pins exactly what it holds;
  nothing is trusted from the environment beyond where to look.
- No capability, authority or device behaviour: a native deployment still needs its mutation
  authority, its capability and the device hold.

## Checks over the fake HDC, after the change

The same isolated daemon, with `ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER` naming the repository's
`Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Resources/OpenHarmonyNativeCodeSign/arkdeck-code-sign-enable`:

| Check | Answer |
| --- | --- |
| `operation list` | `availability` `available`, `reasonCodes` `[]`, `reasons` `[]` |
| `job plan` of the oracle's `deployed.plan` request | exit 0. Every member equals Swift's recorded answer: `authorizationPolicy` `standingCapability`, `effectiveEffect` `deviceMutation`, `executionMode` `planOnly`, `bindingRevision` 1, the Catalog digest `508783ac…`, the request fingerprint, the stable identity, the inputs and the step list |
| `materializedPlanDigest` | differs from Swift's by construction: the materialized plan names absolute host paths, and this owner's helper and library are not at the oracle's. The in-process replay (`tests/native_library_plan.rs`), where every path is the oracle's, pins that digest |

## Tests

| Test | What it proves |
| --- | --- |
| `native_library::tests::the_helper_is_a_static_arm64_executable_without_a_signature` | A synthesized arm64 static ELF with a GNU build id verifies, with the ABI, build id, SHA-256, byte count and host path it carries. An interpreter, no loadable segment, a shared object, another ABI and bytes that are no ELF are each refused |
| `native_library::tests::the_bundled_helper_carries_the_facts_the_oracle_recorded` | The helper ArkDeckWorkflows carries verifies to exactly the facts the oracle recorded for the helper Swift staged: SHA-256 `86497e1a…`, build id `4e6f5302…`, 214 016 bytes, arm64. The isolated contract view keeps only `rust/`, so the test reads the oracle's record always and the helper when the checkout has it |
| `code_sign_helper::tests` (three) | The candidate paths are the resource layouts Swift looks in, in its order; the development variable is an explicit absolute path; a named helper that is missing, is not an ELF, carries an interpreter or is a shared object is refused |
| `operation_availability_control` (extended) | Over the real daemon composition: with no helper the operation keeps its two reasons, and with the verified helper only the mutation owner's remains |
| `tests/managed_hdc_process.rs::the_development_code_sign_helper_is_named_only_where_it_may_be` | Real `arkdeck-agentd` processes: a relative path and a file that does not verify each fail startup with their own message, and the standalone daemon refuses the variable outright. No server starts in any of them |

## Local targeted checks

| Command | Exit | Log SHA-256 |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | `e3b0c442…` (empty) |
| `CARGO_BUILD_JOBS=2 cargo clippy -p arkdeck-provider-hdc -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets --locked -- -D warnings` | 0 | `5bd51953…` |
| `CARGO_BUILD_JOBS=2 cargo test -p arkdeck-provider-hdc -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --locked`: 82 test binaries, 670 passed, 0 failed, 14 ignored | 0 | `6bc97773…` |
| `ARKDECK_PYTHON=<repo>/.venv-sdd/bin/python sh scripts/check-sdd.sh`: 0 errors, 0 warnings | 0 | `77c17376…` |

Those ran on `b958ff448` plus this change. On the head rebased onto `486f9139`, fmt and the same
clippy passed again (`2077735c…`), and so did the same four crates' tests: 85 test binaries, 690
passed, 0 failed, 14 ignored (`9432b3e3…`).

## CI

The PR's CI (`guard` + `swift`) is the unified gate; its run ids and conclusion are recorded by the
next slice or a documentation follow-up.

## Not run

Any device, real HDC or installed Runtime. GJ-3's fake rehearsal follows now that the operation is
available there, and its real-device leg, like GJ-2's, waits for the window.
