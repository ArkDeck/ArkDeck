# Windows trace CRLF representation correction

Implementation/check baseline: `04d9e028be5f80b6d0a68dfffed69998bdcf0575`.
The reviewed increment is synchronized onto protected main
`4d4ee61b7f229dfc7155f646cb73adebba7b58d4`; the intervening recorder/Mac-entry
change does not overlap these ten files. Successful Rust suites are not repeated
for that source-identical synchronization.
This implementation keeps the existing trace families and adds their exact,
homogeneous CRLF transport spelling. It changes no Catalog operation, effect,
Runtime authority, target/binding gate, capture-success criterion or hardware
declaration. The [proposed scoped delta](trace-crlf-representation-scope-review.md)
and separately pinned descriptor are part of the same reviewable increment.

## Observed defect and bounded diagnostic provenance

Root reported a known failed diagnostic-capture Job with zero residue, an empty
available inventory and missing required capture products. It stopped before
product generation with `Trace probe facts do not match target, binding,
adapter, tags, or parameter catalog`. The subsequent typed trace probe had the
correct target/binding and all nine parameters, but no recognized help family.
The old failed Job and captured bytes remain unchanged; this implementation
does not replay it.

Root independently hash-checked the whole captured `trace.probe` CLI stdout envelope
`774d6897e431360537e72326dee6f778d5978619bd2dfa70703dda01a850a6ae`.
This is a captured envelope SHA, not a Runtime Artifact ID or receipt digest.
Its hitrace help was 3,428 bytes with 46 CRLF pairs and no bare CR/LF. Root then
made bounded read-only host HDC diagnostics for both tools' help and tag lists
and verified the following exact bytes. This agent read public repository
source and Root's nonsecret summaries only; it accessed no private Raw,
Runtime state, device, SDK or credentials.

| Tool / diagnostic | Whole stdout SHA-256 | Bytes / CRLF pairs |
| --- | --- | --- |
| hitrace help | `b7f6db5d6816a163b3aea4c8a29ff8d232f11f00630d9fe7efed6e8e012c2a3e` | 3,428 / 46 |
| hitrace tags | `c0b28b5f517dfcf4e694082b80c9ecbc6e1b217b84a23521513f826cf45b1858` | 3,687 / 83 |
| bytrace help | `d1a6bf671b1099f1780c29d74f8d2a54f04f83e148b25a0d827462ec10aea5b1` | 3,428 / 46 |
| bytrace tags | `a09f718916cac81fb6e18183eb001ca18d6399f51959dac87084c85d8cc8fcf4` | 3,687 / 83 |

Every diagnostic had exit 0, empty stderr, no bare CR/LF, and normalized suffix
byte equality to the original registered LF resource. Context was DAYU200,
OpenHarmony 7.0.0.37, the separately registered Windows c2 HDC executable SHA
`c79518498aaf4e719733961216444e70c3eb53c8ba7006b933e6d7f2e1c6101e`.
These are `repoReadOnlyDiagnostic` observations with `formalAcceptance=false`
and `hardwarePass=false`. They are not controlled-human-capture provenance or
formal Runtime hardware evidence.

The previously published GJ-1 trace product was an intentionally omitted missing
declaration. This correction does not relabel that result or its USB, HAR,
observe, HiLog/UI and durable paths; GJ-2 requires a new actual Trace capture.

## Behavior and compatibility

Only a complete, pinned CRLF raw length/suffix fingerprint may enter the
temporary comparison conversion. Every CR must be paired with LF and every LF
paired with CR. The converted bytes must then match the exact original LF
length and suffix SHA. Changed text, bare/mixed endings, duplication,
truncation, trailing bytes, stderr and wrong-tool bytes remain unsupported.
Original raw help and whole hashes are preserved. Hitrace needs its own exact
help and tags; bytrace remains probe-only. The old registry/resource manifest,
all seven goldens, LF oracle and ControlFrames are unchanged.

The current profile/lock advance to `OPENHARMONY-TOOLS@0.8.0` /
`INTEGRATION-PROFILES-0.9.0`. Their additive descriptor SHA is
`e0fe28bd62f0f725d8c24b3e8acd488ddd42c3f8c61af42c717049fa54ecde62`.
Historical registry/profile tuples remain pinned; there is no cross-platform
HDC identity substitution. Compatibility: the legacy pack's timestamp-only
policy is preserved, and the separately reviewed descriptor explicitly names
the only new representation instead of changing historical resources.

## Local targeted checks

All Cargo checks use the stable `health-continuation` owner via
`rust/scripts/run-cargo.py`, jobs 2, an exclusive mirror/target outside the
checkout, the host slot runner and cleared live opt-ins.

| Check | Actual result | Log |
| --- | --- | --- |
| provider trace target | exit 0; 11 passed / 0 ignored | `D:/src/ArkDeck-wt/tools/logs/trace-crlf-provider-focused-native.log` |
| provider/direct-consumer clippy | exit 0; all targets, warnings denied | `D:/src/ArkDeck-wt/tools/logs/trace-crlf-clippy.log` |
| CLI + daemon sibling build | exit 0 | `D:/src/ArkDeck-wt/tools/logs/trace-crlf-cli-daemon-build.log` |
| first affected test invocation | exit 101; agentd 95 passed / 2 account-guard refusals / 3 ignored; later targets not reached | `D:/src/ArkDeck-wt/tools/logs/trace-crlf-affected-tests.log` |
| provider / hoststore / soak complete tests | exit 0; respectively 187/555/5 passed, 0/7/1 ignored | `D:/src/ArkDeck-wt/tools/logs/trace-crlf-remaining-affected-tests.log` |
| account fixture filter after typed drain | exit 0; 3 passed, including both prior refusals | `D:/src/ArkDeck-wt/tools/logs/trace-crlf-account-fixture-drained.log` |
| previously unreached agentd integration targets | exit 0; 86 passed / 0 ignored | `D:/src/ArkDeck-wt/tools/logs/trace-crlf-agentd-unreached-tests.log` |
| workspace-wide format command | exit 1; Windows command-length limit, os error 206 | `D:/src/ArkDeck-wt/tools/logs/trace-crlf-fmt-all.log` |
| exhaustive per-package format / agentd doc tests | exit 0; all 13 packages checked; 0 doc cases | `D:/src/ArkDeck-wt/tools/logs/trace-crlf-fmt-packages-agentd-doc.log` |
| docs SDD / whitespace | exit 0; SDD 0 errors / 0 warnings | `D:/src/ArkDeck-wt/tools/logs/trace-crlf-sdd-initial.log`, `D:/src/ArkDeck-wt/tools/logs/trace-crlf-diff-initial.log` |
| affected Swift class | not run on this Windows host; CI is required | `HDCSupervisorObservationRegistryContractTests` |

Commands use `python rust/scripts/run-cargo.py`: `test -p
arkdeck-provider-hdc --test trace_probe`; `clippy -p arkdeck-provider-hdc -p
arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings`;
`build -p arkdeck-cli -p arkdeck-agentd`; and the affected package tests.
The recovery invocations select only the three account fixtures and the 39
previously unreached agentd test targets, preserving all earlier green results.
Distinct successful Rust coverage is 930 cases / 11 ignored: provider 187,
hoststore 555, soak 5 and agentd 183. Focused/filtered overlaps are not added again.
The required `fmt --all --check` command exceeded Windows' command-line limit;
the equivalent exhaustive `fmt -p <package> --check` checks cover every workspace
member without modifying the formatter. The unreached `test -p arkdeck-agentd
--doc` group also passed with zero cases. Contract input/generator checks are
not applicable because no Catalog, schema, ControlFrame or CLI argv changes.

The original account fixtures and a verified-short-TEMP retry both stopped at
the existing account owner guard while Root's Runtime was still running. The
second failure log is preserved at
`D:/src/ArkDeck-wt/tools/logs/trace-crlf-account-fixture-short-temp.log`.
Root then drained its verified Runtime through the published host lifecycle
leaf, reported state preservation/socket absence and reserved the quiet account
window. Both failed cases passed afterward; the agent never killed a process,
changed ownership/ACLs, cleared a guard or stopped an unknown HDC server. This
is an observed fixture prerequisite, not a code failure or invalid-run claim.

The first sandbox invocation stopped at Git worktree ownership validation
before compilation/tests; its failed log is preserved at
`D:/src/ArkDeck-wt/tools/logs/trace-crlf-provider-focused.log`. The owning-user
invocation passed without changing Git trust configuration. No real-device
test was run by this agent.
The first SDD launcher could not locate `sh` before entering the check; its
reserved log is `D:/src/ArkDeck-wt/tools/logs/trace-crlf-sdd-pre-note.log`.
The explicit installed Git shell then ran the unchanged SDD entry successfully.

## CI

Not yet pushed or run. Root owns public integration, normal PR publication and
the later protected-main Runtime/device acceptance. Local fixture success
does not establish trace capture, GJ-2, paired Mac acceptance or hardware pass.
