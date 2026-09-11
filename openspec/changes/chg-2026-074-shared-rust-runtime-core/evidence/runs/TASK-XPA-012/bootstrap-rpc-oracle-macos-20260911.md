# TASK-XPA-012 — Swift Bootstrap inspection RPC oracle

This bounded slice adds the real Swift producer for `runtime.tool.inspect`
(`tool`, accepting HDC and DevEco references) and `runtime.bundle.inspect`
(`bundle`). It is host-only fixture evidence, not installed activation, device
acceptance, Runtime authority or completion of TASK-XPA-012/018.

Base: `22cf5d29` (fresh protected-main fetch, PR #1849). Worktree:
`/private/tmp/arkdeck-xpa012-bootstrap-rpc-oracle`. No commit or push was made by
this slice. Root integration owns the final unified gate and postmerge
TASK-XPA-002 published Rust pin refresh.

## Producer and read-only behavior

`RuntimeControlPlaneHandler` receives optional async `@Sendable` closures whose
input is an exact reference and output is Core `JSONValue`. Main constructs the
actual Bootstrap registries inside those closures and uses the existing HDC
published-identity lookup and real native trust adapters. There is no captured
non-Sendable registry, unchecked Sendable declaration, new Package.swift
relationship, CLI dependency or raw path request field. The existing Swift CLI
pre-daemon bootstrap leaves are unchanged.

Construction itself does not write, but the former inspection paths opened the
registry with `create: true`, opened `.lock` with `O_CREAT`, and created missing
bundle/tool/DevEco indexes. The new RPC calls use `existingStoreOnly: true`:
existing directory and lock only, existing bundle index plus selected-family
index only, the same nonblocking exclusive lock and strict decoders, and no
initialization or repair. Existing local bootstrap callers retain their original
lazy initialization default. Formats, trust validation and owner references are
unchanged.

All failures produced by this handler include
`{"phase":"bootstrapRegistryOwner","newDispatchCount":0}`. Invalid/extra/missing
fields, non-string inputs and noncanonical references are `invalidParams` before
owner access. An unconfigured closure is `operationUnavailable`. A valid absent
reference is `resourceNotFound`; lock contention is `resourceConflict`. Existing
`admissionDenied` is preserved; other owner errors and unreadable state map to
`recordUnreadable`. Outer protocol/identity failures remain the common control
parser's responsibility.

## Genuine recording provenance

The committed uncompressed input directory is
`bootstrap-rpc-native-frames-macos-20260911/`: 126 actual handler frames in five
original recorder files, each copied byte-for-byte from
`/private/tmp/xpa012-bootstrap-rpc-frames/`. They preserve all genuine recorded
runs, including actual refusals from the initial sandboxed run, the native
positive/refusal runs, the retained combined-owner run, and the final selected
HDC/unsigned run. No frame was synthesized or edited. Duplicate observations
from reruns are intentional generator inputs, not distinct coverage claims.

Positive inputs passed real native verification:

- HDC-shaped host candidate: `/usr/bin/true`, copied and registered normally;
  never selected or executed and never reported as a published HDC identity.
- Bundle: the existing signed
  `/Users/fuhanfeng/Library/Application Support/ArkDeck/Helpers/ArkDeckAgent.app`,
  copied into the fresh fixture registry and checked by
  `LaunchAgentService.validateProductionDaemonBundle`.
- DevEco: `/Applications/DevEco-Studio.app/Contents`, registered and rechecked
  through the real code/publisher/resource verification paths.

The explicitly adversarial negative test uses the existing registry fixture
pattern to construct unsigned, non-executable stored input. Its injected
registration acceptance is never recorded as success. Only the actual
production native verifier's `admissionDenied` response crosses the handler and
recorder. No success trust frame uses injected acceptance. Structural malformed
request tests disable the recorder; a real invalid reference string records the
`invalidParams` error while keeping the typed request field set closed.

Sandboxed native verification was refused by macOS. The permitted unsandboxed
host test run passed without weakening native verification or executing an inspected candidate.

## Selected HDC and genuinely unsigned metadata

The host-gated selected HDC test consumes only the explicit reference
`tool:sha256:adcf3a3c1fa05fdee3ca2523986bfcc128e8a2106c1ece3b7e018f81b6370f35`
from the actual getpwuid-derived Bootstrap/v1 owner, using existingStoreOnly.
There is no registration, selection, repair or write in this test. It compares
the original bundles.json, tools.json and deveco-toolchains.json bytes and the
full recursive member set before/after. All are unchanged. The real response
contains selected=true, activeSelectionGeneration="1", one libusb dependency,
registeredIdentity=true, toolVersion="3.2.0f", and the current published profile
references. These are observed native/registry projections, not fixture facts.

The unsigned test copies `/usr/bin/true` into a fresh private fixture and runs
`/usr/bin/codesign --remove-signature` on that copy only. It never executes the
candidate or changes the system source. The real Security.framework inspector
reports unsigned with null identifier/team/code-directory metadata; normal
registry registration and RPC inspection preserve those nulls. No injected
signature acceptance is used. This genuine input was necessary: the earlier
signed-only corpus constrained signingIdentifier and codeDirectoryIdentitySHA256
to strings. The regenerated tool schema now covers their null values and the
selected HDC's string generation, dependency and published-identity shapes.

## Generation and identity migration

The existing generator was run on that unmodified raw input:

```sh
python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py \
  --derive-method-schemas openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-012/bootstrap-rpc-native-frames-macos-20260911
```

It generated only the two new method schemas and their selected corpora. Its
warning about no new recording for the existing 97 methods is expected: those
methods were not re-derived from their compressed corpora. Each existing schema
was loaded from the base, only `x-arkdeck-contractIdentity` was changed to the
identity emitted by the generator, and its `$defs` and every other field were
compared to the base. At this producer step all 97 old corpus files remained
byte-identical. The final integration separately re-records health from the actual
99-method registry, because its result embeds the registry identity and method
count. The other 96 old corpus files remain byte-identical. Existing method
definitions are preserved to retain error vocabulary absent from a compressed
corpus.
The recorder intentionally omits contract identity from corpus rows; no old
recording was edited or relabeled as a new execution.

Current identity:
`05a9f1ad8309a0cd23666bf00aa07eb4c04f317e882183f9aa612568faf64492`.
The method count is 99 on protocol `1.0.0`. Existing binaries using the old
identity do not match this candidate; paired build/deployment and published pin
refresh belong to integration.

The actual built `arkdeck maintainer contracts export` was run into temporary
output directories. Only its changed `runtime-control-plane.schema.json` was
copied back; all other contract products were identical. The real
`maintainer contracts check` checked 235 products with zero drift, missing or
unexpected files. No Rust source, generated Rust baseline or pins were edited.

## Validation and retained process fixture

The retained-root native run passed 9 tests without failures or skips. The final
expanded run executed 11 tests: 10 passed and the opt-in retained-root test was
skipped because that output root had already been created and retained; no test
failed. It additionally recorded a read of the existing selected HDC and a real
unsigned temporary tool. Four existing Bootstrap registration/inspection
regressions passed with recording disabled. Four ControlMethodSchemaContractTests
passed after re-deriving the two new schemas from all 126 genuine raw frames,
including every live recording. `generate-control-contract.py --check` and
`git diff --check` passed.

Logs:

- `/private/tmp/xpa012-bootstrap-rpc-native-retained.log`
- `/private/tmp/xpa012-bootstrap-rpc-selected-unsigned.log`
- `/private/tmp/xpa012-bootstrap-rpc-schema-expanded.log`
- `/private/tmp/xpa012-bootstrap-rpc-legacy-regression.log`
- `/private/tmp/xpa012-bootstrap-rpc-schema-final.log`
- `/private/tmp/xpa012-bootstrap-rpc-export-check.log`

The Bundle, DevEco, existing-selected-HDC and retained-root tests are host-gated
for ordinary CI. The explicit
`ARKDECK_BOOTSTRAP_RETAIN_FIXTURE_ROOT` option accepts only a fresh
`/private/tmp/` target and preserves that one fixture for process comparison.
The retained Bootstrap root is:
`/private/tmp/xpa012-bootstrap-rpc-native-fixture-20260911/bootstrap`.
It contains the actual HDC, signed Bundle and DevEco registry products. Its
parent is suitable as the isolated Rust development state root. The test prints
only that retained root path and verifies that reads preserve file content and
permissions. No binary or durable fixture index is committed to Git.

Required bounded scope extensions under TASK-XPA-012:

```text
Scope-Extension: Packages/ArkDeckKit/Contracts/control-protocol.json
Scope-Extension: spec/control/methods/*.json
Scope-Extension: openspec/contracts/runtime-control-plane.schema.json
```

The method wildcard covers two additive contracts and identity-only metadata
refresh in the unchanged methods. The Swift source/test/evidence paths are
already covered by TASK-XPA-012. No Package.swift target/dependency extension is
needed.
