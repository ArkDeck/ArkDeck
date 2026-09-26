# The App ingress answers at its door as Swift's App transport does (TASK-XPA-019, macOS, 2026-09-26)

TASK-XPA-019 / CHG-2026-074. #2249's record listed, under "Left open", the door refusals of the Rust
App ingress that differ from Swift's App transport
(`TASK-XPA-013/import-app-and-cli-refusals-run.md`):
- the Job gate's `rejected`, where Swift answers `methodNotAllowlisted`;
- the closed-parameter checks of the storage and session methods;
- the words of the undecodable-frame refusals.

The hub proposed aligning them on 2026-09-26, and the coordinator agreed, on these terms:
- **Only the ingress's refusal codes, words and order change.** It admits no method it did not
  admit before.
  - `session.*` stay refused as a whole (#2250), so their closed parameters are not taken up.
  - `runtime.storage.*`, which the App's Settings page sends, take Swift's closed parameters one
    by one, cited by line. Rust then admits exactly what Swift admits and refuses exactly what it
    refuses.
- **Swift-recorded frames as the oracle.** The Job gate's refusals and the undecodable frames'
  words are replayed byte for byte from them, and `rust/scripts/macos-xpc-probe.swift` expects
  the same.
- **Zero dispatch asserted as X3 does it:** the dispatch count, the owners' calls and the store's
  files.
- **No contract input changes.**

Base: protected `main` `20130b631` (#2254). Nothing here is device evidence.

## What Swift answers: the oracle

`AppIngressDoorOracleContractTests` records into
`rust/tests/fixtures/app-ingress-door-oracle/cases.json` (`provenance.json` beside it).
- **Each case goes through `AgentXPCEndpoint.responseFrame`** (`AgentFacadeOrigin.swift:109–135`),
  the frame the App's raw XPC listener sends back, with a fresh App Job gate. The handler has no
  storage, Target or Artifact owner.
- **A refusal is recorded byte for byte.** A request the door lets through is recorded as
  `forwarded` only, and checked against `AgentXPCEndpoint.admission` for every method except
  `job.run` and `job.cancel`, whose refusal is the gate's.
- **64 cases:** 12 frames, 14 Job requests and 38 storage requests; 55 refused and 9 forwarded;
  no dispatch.
- **Recorded in a Swift window the hub granted,** 10:49–10:51.
  - Without the recording variable, the same test compares Swift's answers with the file: exit 0.
  - With one code in the file altered: exit 1.

Every door refusal is `{"error":{"code":…,"message":"Runtime transport refused this request"},"id":…,"ok":false}`
and a newline, with no details (`AgentFacadeOrigin.swift:137–145`). The code and id are:

| Request | Code | Id |
| --- | --- | --- |
| A frame Swift cannot read: not JSON, not an object, empty, a missing or empty `id`, an unknown member, `params` not an object, a duplicate member, a trailing newline | `malformedFrame` | `""` |
| Another protocol version or contract identity | `unsupportedProtocolVersion` | the frame's |
| A method this Runtime does not publish | `unknownMethod` | the frame's |
| A Job request outside the typed gate: an untyped submit or plan, a missing or extra parameter, a request that is not a string, a bad Job id | `methodNotAllowlisted` | the frame's |
| A run or cancel of a Job the App did not submit (`AgentXPCListener.swift:145–155`) | `methodNotAllowlisted` | the frame's |
| A storage request outside its closed shape | `methodNotAllowlisted` | the frame's |

### Swift's closed storage shapes

`AgentXPCListener.swift`:
- **`runtime.storage.status`** (`:184–187`): no parameters, or `{}`.
- **`runtime.storage.policy`** (`:260–265`): exactly its four members, each a positive decimal
  string (`:252–258`): digits only, no leading zero, at most Int64's maximum.
- **`runtime.storage.root`** (`:266–275`): a positive `expectedGeneration` and exactly one of:
  - `rootPath`: a string of 1 to 4,096 UTF-8 bytes, starting with `/`, with no white space or
    newline at either end;
  - `resetToDefault: true`.
- **Anything else** gets no admission (`:188–191`), and `responseFrame` refuses it.

The oracle holds both sides of each bound:
- **Admitted:** Int64's maximum; a path with a space inside; a 4,096-byte path; a path with a
  control character; the reset.
- **Refused:**
  - a count beyond Int64, or spelled `"0"`, `"030"`, `"-1"`, `"+1"`, `" 1"`, `""`, or as the
    integer 30;
  - a missing or extra member, or a generation of `"0"`;
  - an empty or relative path;
  - a space, tab, newline, no-break space (U+00A0) or ideographic space (U+3000) at an end;
  - 4,097 bytes, of ASCII or of 2,048 `é`;
  - both members, `resetToDefault` false or `"true"`, no generation, or the generation alone.

## Change

`arkdeck-agentd` `app_ingress.rs`:
- **Undecodable frames** are refused in Swift's words.
  - `malformedFrame` answers under the id `""`; it used `-`.
  - Another version or contract, and an unknown method, answer under the frame's id, or `""` if
    it has none (`frame_id`), as Swift does.
- **The Job gate refuses with `methodNotAllowlisted`:** a request `jobs::Action::parse` refuses, a
  run the gate cannot begin, and a cancel of a Job it does not own. They were `rejected`, in the
  ingress's own words.
- **Storage requests are checked at the door,** beside the Import begin, by
  `app_ingress/storage.rs` `admitted`: Swift's shapes, refused with `methodNotAllowlisted`.
  - `closed_parameters` no longer checks them; it answered `invalidParams`.
  - The schema check it added is implied by Swift's shapes: the three request schemas only type
    the members as strings or a boolean, with no others.
- **What the ingress admits is unchanged,** except storage requests, which it now admits exactly as
  Swift's door does:
  - the allowlist;
  - the Job gate's typed pairs, #2118's read-only continuation included;
  - every other method's closed parameters.
- **The storage root is narrower at the door than it was,** and never wider.
  - A relative, empty or over-long path, or one with white space at an end, now stops at the door
    (`AgentXPCListener.swift:248–279`). The owner used to refuse it behind the door.
  - The policy and the status admit what they admitted.
  - The App met the same bounds at Swift's door, so nothing it sends is refused that Swift admitted.

`rust/scripts/macos-xpc-probe.swift`:
- **Contract mode adds:** another protocol version, an unknown method, an untyped submit, a storage
  status with a parameter and a relative storage root. It checks every refusal's words.
- **The probe reads the protocol version and contract identity** from this checkout's
  `spec/control/methods/health.json`.
  - The identity it carried, `8a662759…`, was the contract of #1833, when the probe was written.
  - Against the current Runtime, every one of its requests was refused as another contract.
  - A stale value, fixed in passing.
- **Not run here:** it needs the signed daemon and facade. `swiftc -typecheck` exits 0.

## Tests

**New: `app_ingress/door_tests.rs` `the_door_answers_every_frame_as_swift_s_app_transport_does`.**
Every oracle case goes through the ingress in order, over a Host whose storage requests reach an
actual `SessionStore` and whose Job lifecycle records and refuses each call.
- **A refused case:** the reply is Swift's bytes. The files under the root, the dispatch count and
  the owners' calls are as they were.
- **A forwarded case:** the dispatch count grows by one, and exactly its method reaches its owner.
- **55 refused and 9 forwarded.**

**Updated:**
- **`job_tests.rs`:** the gate's refusals are `methodNotAllowlisted`. The peer checks stay
  `rejected`.
- **`tests.rs` `rejected_origins_methods_frames_and_parameters_never_enter_control`:** a Job method
  with `{}` gets the transport's frame, like every other refused method. A storage status with a
  parameter stops at the door.
- **`storage_tests.rs`:**
  - malformed settings are `methodNotAllowlisted`;
  - a relative root now stops at the door, with no dispatch;
  - the unsafe-root test sends a path with a NUL instead, which Swift's door lets through and the
    owner refuses (`invalidInput`).
- **`tests/spawning/app_ingress_fake_hdc.rs`:** a second run of a Job the App ran, and a run or
  cancel of a Job submitted over the socket, are `methodNotAllowlisted`.

**Negative controls on the new test,** each failing at the first case of its kind:
- **the old words for an undecodable frame:** `frame.notJson`;
- **the old `rejected` for a Job request outside the gate:** `job.submit.cliClient`;
- **no storage check at the door:** `storage.status.parameter`, which reached the owner and got
  `invalidInput` "Storage status accepts no parameters".

## Left open

- **The door's closed-parameter checks of the other methods it admits** still answer
  `invalidParams` in the ingress's words. These are the reads, History filters, Trace cache, the
  Debug and Trace probes, the Flash reads, the Loader binding and the three upload follow-ups.
  Swift's door forwards them (`AgentXPCListener.swift:197–213`) and leaves their parameters to the
  Runtime. Outside this slice's terms.
- **`session.*`** stay refused as a whole (#2250).
- **An unauthenticated peer** stays `rejected`; Swift's listener cancels the connection.
- **X5** stays a declared difference (#2132).
- **The Rust-only `internalError`** when a submit's receipt cannot be recorded stays.

## Contract

No contract input changes. `methodNotAllowlisted` stays outside every method schema, as #2249
left it.

## Local targeted checks

On `20130b631`, 10:49–11:06, before the hub's 12:20–13:10 quiet window. Rust with
`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-vj-rust-target`, logs in
`/private/tmp/arkdeck-vj-logs/`.

- **Swift oracle, in the hub's window** (`door-oracle-record.log`, `door-oracle-compare.log`):
  - `ARKDECK_APP_INGRESS_DOOR_ORACLE_OUTPUT=<new path> sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh
    test --filter AppIngressDoorOracleContractTests`: exit 0, 64 cases.
  - The same without the variable: exit 0. With one code in `cases.json` altered: exit 1; the file
    was restored.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-agentd --all-targets -- -D warnings`:
  exit 0 (`s38-clippy.log`).
  - The same with `--target x86_64-pc-windows-msvc` and with `--target x86_64-unknown-linux-gnu`:
    exit 0 each (`s38-clippy-cross.log`).
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --no-fail-fast`: exit 0
  (`s38-test.log`): 22 suites, 188 passed, 0 failed.
- The three negative controls above.
- `xcrun swiftc -typecheck rust/scripts/macos-xpc-probe.swift`: exit 0.
- `sh scripts/check-sdd.sh`: exit 0.
- **After the rebase onto `5d42490da`** (#2255–#2257, the M4 lane's cutover preflight, Rockchip
  host records and Flash session, which touch none of these files; `s38-rebased.log`): fmt and
  the same native clippy exit 0; the same `cargo test -p arkdeck-agentd`, exit 0, 22 suites, 192
  passed, 0 failed.
- **Then onto `e58dda2bb`** (#2258, a cutover runbook draft under `docs/`, no code):
  `sh scripts/check-sdd.sh`, exit 0.

**Not run:**
- `generate-contract.py --check` and `check-contracts.py`: no contract input changes.
- The probe against a signed daemon, the App and a device.

## CI

#2259, head `58b877055`, run 36213881779: every selected lane passed.
- Rust workspace: macOS 12m16s, Ubuntu 1m46s, Windows 3m53s. Host-independent checks: 41s.
- `swift-tests`: 7m45s. `ds-interactions` passed.
- `guard` (run 36213881531); `swift` aggregate. `app-build` was not selected.

It merged as `784641012`. Recorded by the next slice (TASK-XPA-017, the cutover runbook's appendix B
verification), as AGENTS.md has it.
