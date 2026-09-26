# What the App and the CLI receive when an Import request is refused (TASK-XPA-013, X3–X7)

This follows #2241, which gave the Import owner's refusals Swift's words.
The coordinator ruled the next items after a recording of Swift's real
answers:

- X3: the App transport's refusal of a request outside its allowlist;
- X4: the App's uploads on a daemon without its Import owners;
- X6: the Import arguments the Rust CLI refused itself where Swift's CLI asks
  the Runtime;
- X7: the native-library file name refusal.

Base: protected `main` `167783bb1`. The work began on `eec3df485` (#2241),
where Swift's answers were recorded; no Swift source changed between the
two. No contract input, method schema, corpus line, Catalog or `tasks.md`
changes. The App transport's allowlist admits exactly the methods it
admitted before.

## What Swift answers: the oracle

`ImportAppRefusalOracleContractTests` records Swift's answers into
`rust/tests/fixtures/import-app-refusal-oracle/cases.json`. Without its
recording variable it compares Swift's answers with that file byte for byte.

- **App cases** go through `AgentXPCEndpoint.responseFrame`: the frame the
  App's raw XPC listener sends back, which is what ClientKit decodes. A first
  recording through `sendRequestFrame` kept only the endpoint's refusal
  reason, which the App never sees, so the cases were recorded again.
- **CLI cases** run Swift's `arkdeck` against the same handler's daemon, and
  keep the exit status, the machine output and the standard error.

| Case | What the App or the caller receives from Swift |
|---|---|
| `list`, `inspect`, `inspection`, `release` on the App transport | `{"id":…,"ok":false,"error":{"code":"methodNotAllowlisted","message":"Runtime transport refused this request"}}`, with no details and no other field |
| An App `begin` of another kind (`workspace-patch`), or with complete but invalid metadata | the same frame: `AgentXPCListener.admission` admits a begin only for a valid intent of one of the App's three kinds |
| An App `append` of an Import the Runtime never began (X5) | `admissionDenied` "Import is outside this App upload scope", phase `preAdmission` |
| An App `begin` on a daemon without the Import owners (X4) | `operationUnavailable` "Import owner services are unavailable", phase `importOwner` |
| An App `append`, `abort` or `commit` on that daemon (X4) | `admissionDenied` "Import is outside this App upload scope", phase `preAdmission` |
| `artifact import inspect` with no selector, or with both | refused by the registry before any request: `invalidOption` "`artifact import inspect` requires exactly one of --import, --import-request-id", exit 64 |
| `artifact import list --target ../target` | sent as given; the Runtime's `invalidInput` "Import filter is invalid", exit 65 |
| `artifact import list --cursor ""` | sent as given; the Runtime's `invalidCursor` "invalid Import cursor", exit 65 |
| `artifact import native-library` of a file named `fixture.bin` | nothing on stdout, even with `--output json`; stderr "arkdeck artifact: native library file must have a safe lib*.so basename or an exact ArkDeck export name ART-<32 lowercase hex>-lib*.so"; exit 64 |

`methodNotAllowlisted` is in no method schema, and the corpus holds no App
frame. Swift's listener sends it outside every schema, and ClientKit's
transport checks only the envelope.

## What changes

**X3, the App transport's refusal (T0).** By the coordinator's ruling (a),
the Rust App ingress answers a request outside its allowlist with Swift's
frame, `methodNotAllowlisted` "Runtime transport refused this request", with
nothing else and no schema change (`app_ingress.rs`, `not_allowlisted`). It
used to answer `rejected` "method is not available through the standalone
App ingress".

- A `begin` is admitted at the door only for a complete, valid Import intent
  of a HAP, a native library or a Flash bundle
  (`app_ingress/imports.rs`, `admitted_begin`, which replaces
  `out_of_scope`). Any other begin gets the same frame and reaches no owner.
  - Before this change, another kind answered `admissionDenied` (phase
    `preAdmission`).
  - Invalid metadata answered `invalidParams`, or reached the owner.
  - The three kinds are the ones Swift's listener admits, and the ones the
    ingress admitted since the App's Flash bundle upload.
- **This applies to every method outside the ingress's allowlist, not only
  Import methods: 70 of the 105.**
  - 60 are refused by Swift's App transport too, and now receive the same
    frame: agent.abandon, agent.list, agent.resume, agent.run, agent.status,
    artifact.export, artifact.import.inspect, artifact.import.inspection,
    artifact.import.list, artifact.import.release, capability.inspect,
    capability.list, cleanupDebt.continue, cleanupDebt.list,
    control-action.list, control-action.reconcile, control-action.show,
    debug.evaluate, debug.start, debug.status, debug.template.run,
    device.display-name.clear, device.display-name.set, doctor,
    flash.reconcile-alias, human-action.list, human-action.resume,
    human-action.show, job.events, job.reconcile, job.result,
    operation.describe, recovery.flash-invocation.list, runtime.bundle.inspect,
    runtime.bundle.list, runtime.bundle.register, runtime.bundle.remove,
    runtime.hdc.impact-preview, runtime.hdc.restart, runtime.tool.inspect,
    runtime.tool.list, runtime.tool.register, runtime.tool.remove,
    runtime.tool.select, target.adopt, target.availability,
    target.display-name.clear, target.display-name.set, target.show,
    trace.inspect, workspace.preset.list, workspace.preset.register,
    workspace.preset.remove, workspace.preset.show, workspace.preset.update,
    workspace.project.list, workspace.project.register,
    workspace.project.remove, workspace.project.show, workspace.project.update.
  - 10 are admitted by Swift's App transport and refused by this ingress:
    artifact.inspect, job.status, session.cleanup.apply,
    session.cleanup.preview, session.export.apply, session.export.preview,
    session.list, session.pin, session.show, session.unpin. They now receive
    `methodNotAllowlisted` where Swift answers the method. Which methods the
    ingress admits is a separate decision (below), not this change's.
- Unchanged:
  - The four Job methods keep their own typed gate: `rejected` "a closed
    typed App Job request is required", and the refusals of a Job not
    runnable or not owned by the App.
  - The other three uploads' closed shapes keep `invalidParams`.
  - A frame this ingress cannot decode keeps its answers.
  - An unauthenticated peer keeps `rejected`.

**X4, the App's uploads without the Import owners.**

- `arkdeck-agentd` `Host::app_import_resource` refuses an App `append`,
  `abort` or `commit` without the Import or Artifact owner as Swift's
  gateway does: `admissionDenied` "Import is outside this App upload scope",
  phase `preAdmission`.
- A `begin` keeps the owner's "Import owner services are unavailable".
- `arkdeck-control`'s host without an App Import owner answers the same
  four, where it answered "App Import owner services are unavailable" for all
  of them.
- The three methods' schemas already publish `admissionDenied`, and their
  details take any phase.

**X6, the CLI's list and inspect.**

- `artifact import list` sends `--target` and `--cursor` as given, and the
  Runtime's refusal is the answer. It used to refuse them itself with
  `invalidOption` "Import requires its exact request identity, owner and
  options". The registry still bounds `--state` and `--page-size` first, as
  Swift's does.
- Two `configure` checks stay, though they look dead. This CLI's `parse`
  consults the registry only when its own reading fails, and the registry's
  refusal then replaces its own (`lib.rs`, `reported`). Each check is what
  makes the registry answer in Swift's words:
  - `artifact import inspect`'s selector count, for `requiresExactlyOneOf`.
    The coordinator's ruling assumed this check was dead and could be
    deleted. Without it, both inspect cases reached the Runtime: the replay
    hung on its fake Runtime, and the binary answered `runtimeUnavailable`.
  - `artifact import list`'s state, for the registry's enumeration. Without
    it, `--state unknown` reached the Runtime
    (`import_resources::import_list_maps_only_closed_discovery_options`).
    The page size's conversion already refuses its bounds.

**X7, the native-library file name.**

- The refusal is Swift's plain usage failure: the message on stderr as
  `arkdeck artifact: …`, nothing on stdout, exit 64.
- `CliError` carries it as `plain_exit` (`CliError::plain_usage`), and the
  CLI's main renders it before any other rendering.
- The name check also takes Swift's 128-character bound.

## Tests

| Where | Test | Holds |
|---|---|---|
| agentd | `import_tests::app_transport_refusals_are_the_frames_swift_s_app_receives` | the 11 oracle App cases through the ingress, with the production owners or a Host without them, each frame byte for byte against the oracle; X5 as its declared answer. A refusal at the door leaves the dispatch count, the owner's steps and the store's files as they were |
| agentd | `import_tests::a_request_outside_the_app_allowlist_gets_swift_s_transport_refusal_and_nothing_else` | ten methods, four Import methods, three Swift admits and three neither admits: exactly `error` (code and message), `id` and `ok` |
| agentd | `tests::rejected_origins_methods_frames_and_parameters_never_enter_control` | every method outside the allowlist, now against Swift's frame and no longer decoded by the method schema; the Job methods keep their gate |
| agentd | `import_tests::malformed_uploads_other_kinds_and_foreign_peers_never_enter_the_owner` | a malformed or other-kind begin is refused at the door as Swift's |
| control | `read_only` | the host without an App Import owner answers the oracle's four frames |
| CLI | `import_cli_refusal_oracle` | the 5 oracle CLI cases through this CLI's binary against a fake Runtime answering as Swift's daemon did: exit status, machine output and stderr |
| CLI | `import_resources::import_list_maps_only_closed_discovery_options` | the target and the cursor reach the request as given; an unknown state, an out-of-bounds page size and a file are still refused before any request |

## Left open

- **The App allowlist.** Swift's App transport admits `artifact.inspect`,
  `job.status` and the eight `session.*` methods, which this ingress
  refuses. Recorded here for a separate decision, by the ruling. No method
  is only in the Rust ingress's allowlist.
- **Other door refusals that differ from Swift's**, not changed here:
  - the Job gate's `rejected`, where Swift's `admission` answers
    `methodNotAllowlisted` for an untyped submit or an unowned run or cancel
    (`rust/scripts/macos-xpc-probe.swift` expects that);
  - the closed-parameter checks of the storage and session methods;
  - the words of the undecodable-frame refusals: Swift's are "Runtime
    transport refused this request", this ingress's "App ingress requires the
    exact current request frame".
- **X5** stays a declared difference (#2132): an App append of a missing
  Import is `resourceNotFound` here, `admissionDenied` in Swift.

## Verification

**Local targeted checks.** `CARGO_BUILD_JOBS=2`, own target
`/private/tmp/arkdeck-sleepy-allen-1abe73-rust-target`. The Swift rows ran on
`eec3df485` in SwiftPM windows the hub granted. The other rows ran on
`167783bb1`, after the rebase.

| Check | Command | Result |
|---|---|---|
| Swift oracle | `ARKDECK_IMPORT_APP_REFUSAL_ORACLE_OUTPUT=<new path> sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter ImportAppRefusalOracleContractTests` | exit 0; 11 App and 5 CLI cases |
| Swift comparison | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'ImportAppRefusalOracleContractTests\|ImportRefusalOracleContractTests'` | exit 0; 2 tests, 0 failures |
| Format | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 |
| Lints | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-agentd -p arkdeck-cli -p arkdeck-control --all-targets -- -D warnings`, natively and with `--target x86_64-pc-windows-msvc` and `--target x86_64-unknown-linux-gnu` | exit 0 each |
| Rust | `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd -p arkdeck-cli -p arkdeck-control` | exit 0; 625 passed, 0 failed |
| Records | `sh scripts/check-sdd.sh` (validation venv) | exit 0; 0 errors, 0 warnings |

**CI.** This pull request's lanes; the result is recorded outside this
commit.
