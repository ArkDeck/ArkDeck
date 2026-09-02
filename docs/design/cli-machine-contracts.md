# CLI machine contracts

Task: TASK-AIN-026 (product spec §14, §15.1, §18)

`openspec/contracts/cli-*`, `app-product-capability-registry.yaml`,
`runtime-control-plane.schema.json` and
`Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI/**` are generated
from the build that publishes them. Nothing in the bundle is restated by hand:
every product is a projection of a Swift fact source the CLI already owns, and
a contract test holds the committed files to the binary. A registry change
that forgets to regenerate the bundle fails the Swift lane; a bundle edited by
hand fails the same test.

## Entry point

```bash
arkdeck maintainer contracts export --contracts-directory openspec/contracts --fixtures-directory Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI
```

```bash
arkdeck maintainer contracts check --contracts-directory openspec/contracts --fixtures-directory Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI --output json
```

`export` writes every product and removes stale fixture files; `check` compares
bytes and exits 1 (`operationFailed`) listing `drifted`, `missing` and
`unexpected` paths. Neither leaf connects to the Runtime, reads a device, or
takes any input other than the two directories; both are `local` maintainer
tooling and are macOS-only until a Windows profile is ratified.

`CLIMachineContractTests.testPublishedBundleMatchesThisBuild` runs the same
`check` against the repository, so the Swift lane is the fail-closed gate.

## Products and their fact sources

| Product | Fact source | Notes |
|---|---|---|
| `cli-command-registry.yaml` | `CLICommandRegistry` via `CLIRegistryProjection` | byte-equal in content to `arkdeck commands --output json`; carries `lifecycleStatus`/`replacementArgvPattern` on every leaf (tombstones report `removed`), plus the Catalog digest |
| `cli-error-registry.yaml` | `CLIErrorCode`, `CLIExitCategory` | codes in registry order with category, exit code, `controlRequestRetryable`, `attentionRequired`; categories with their exit codes and member codes |
| `cli-canonical-json-vectors.json` | `PortableCanonicalJSON` | the canonical text of each vector is computed by this build's encoder, never typed in; rejections record the refusal the encoder actually gives |
| `cli-feature-coverage.json` | union of `CLIControlMethodRegistry.classifiedMethods`, `RuntimeOperationCatalog.operations`, `AppProductCapabilityRegistry`, `CLICommandRegistry` | see below |
| `app-product-capability-registry.yaml` | `AppProductCapabilityRegistry` (ArkDeckWorkflows) | every reviewed App surface from `docs/design/implementation-coverage.json` plus the Trace/Help menu commands, with owner, classification and CLI-equivalent argv patterns |
| `cli-result.schema.json` | `CLIResultEnvelope`, `CLIErrorCode`, `CLIControlRequestID` | `error.code` enum is the registry; `meta.controlRequestId` pattern is the parser's grammar |
| `cli-page.schema.json` | §7.3 | `pageKind` conditionals: event pages fix `order` and always carry a cursor; exhausted snapshots carry `null` |
| `cli-event.schema.json` | `CLIEventEnvelope` | terminal frame vs Runtime event frame |
| `cli-next-action.schema.json` | §7.3 union | one closed branch per `kind`; resource kind mirrors owner kind where the spec says so |
| `runtime-control-plane.schema.json` | `AgentWireProtocol`, `ArkDeckControlProtocol` | request/response frames; `method` enum is the classified method set plus the bootstrap method, annotated with 2.x publication |

`--version --output json` reports `pageSchemaVersion` and
`nextActionSchemaVersion` as `arkdeck.cli.page/1` and
`arkdeck.cli.next-action/1`; both constants live in `CLIMachineContracts` and
are the titles of the corresponding schema files.

## Feature coverage

`cli-feature-coverage.json` has one entry per feature, keyed by `source`:

- `daemon:<method>` — every method `CLIControlMethodRegistry` classifies, plus
  `protocol.negotiate`. The generator refuses to run when a classified method
  has no ruling in `CLIMachineContracts.FeatureCoverage.daemonMethodCoverage`,
  so a new daemon method cannot enter the registry without a coverage
  decision. A ruling is one of: fronted by a leaf (with optional compatibility
  spellings, e.g. `debug.start` is reached by `recovery flash-invocation start`
  and the legacy `debug start`), closed plumbing behind a leaf (`internal`),
  a refused stub (`refused`), or the bootstrap.
- `catalog:<reference>` — every published operation. `direct` when a leaf
  declares it as `catalogOperation`; `generic` otherwise, reachable through
  `job submit --operation <ref>`. Today only the `flash.dayu200` alias is
  generic.
- `app:<surface>` — every App capability, with the classification the App
  registry declares (`direct`/`local`/`presentation`/`platformService`/
  `refused`) and its CLI-equivalent patterns, each of which must resolve to a
  registry leaf.
- `cli:<command>` — leaves nothing above reaches (meta commands, host tooling,
  tombstones). Their classification derives from the leaf: `refused` for
  tombstones and refused stubs, `local` for host-side product resources,
  `direct` otherwise.

Every leaf must be referenced by at least one entry, every `targetCommand` and
`equivalentCommands` pattern must resolve to a leaf, feature ids are unique,
and `classification == targetClassification` unless the entry is `blocked`.
`implementationStatusByPlatform` follows §14: `implemented` on macOS for a
closed entry, `partial` for `blocked`, and `notImplemented` for Windows, which
has no ratified profile. `requiredPlatforms` is `["macos"]` for host-specific
families (`legacy`, `agentd`, `signing`, `update-feed`, `maintainer`, `runtime
service|signing|bundle|tool|update|support-bundle`, every frozen 1.x leaf and
every App surface) and `["macos", "windows"]` otherwise.

`summary.fullFunction` is `true` exactly when no entry is `blocked`. It is the
§18 machine gate for macOS; it does not replace Golden Journey device
evidence.

## Fixtures

`Fixtures/CLI/argv/<command>.json` holds, per leaf, the argv cases the parser
is replayed against: `valid`, `leafHelp`, and for executable leaves
`unknownOption`, `duplicateOption`, `missingRequired` (when the leaf has a
required option, exactly-one group or required positional), `jsonlRefused`
(when `--output` is accepted but `jsonl` is not), `endpointRefused` (leaves
that never connect) and `macosCompatibilityOption` (`--socket`). The expected
outcome records the invocation kind or the error code, category and exit
status — never the prose. Sample values come from the option grammar
(`positiveInteger` → lower bound, `enumeration` → first member, `hexDigest` →
zeros, `duration` → `1s`, opaque → `sample`), and the generator itself refuses
to emit a fixture whose `valid` argv does not dispatch to its own leaf.

`Fixtures/CLI/envelopes/` holds rendered `arkdeck.cli.result/1` and
`arkdeck.cli.event/1` documents with the fixed correlation id
`ctl-fixture-0001`; `next-action/` and `page/` hold one document per union
branch and page kind. `index.json` lists every file.

A Windows port replays `argv/**` through its own parser and compares the
`expected` objects; it validates its own envelopes against the schemas. The
Swift tests validate every fixture against its schema and prove each schema
rejects at least one counterexample, so a schema loosened by hand fails too.

## What changed in the App

`ArkDeckApp/**` only registers stable feature ids: `ArkDeckNavigationItem`,
`DebugWorkspaceTab` and `ViewerInspectorTab` each map exhaustively to an
`AppNavigationCapability`/`AppDebugTabCapability`/`AppViewerTabCapability`
case whose raw value is the registry id. No interaction, navigation or visible
text changed, so no design mirror is touched.

## Verification record

- `CLIMachineContractTests` (drift, determinism, YAML round-trip, coverage
  closure and vocabulary, argv replay, envelope and schema acceptance with
  counterexamples, App registry cross-check against
  `implementation-coverage.json`, export/check behaviour in a temporary
  directory) and `CLICommandRegistryCoverageContractTests` pass in the Swift
  lane.
- Drift canary (2026-09-02): editing `argv/job.status.json`, appending a
  line to `cli-error-registry.yaml` and adding `argv/stray.json` made
  `arkdeck maintainer contracts check` exit 1 with
  `drifted: [contracts/cli-error-registry.yaml, fixtures/argv/job.status.json]`
  and `unexpected: [fixtures/argv/stray.json]`; `export` restored the bundle
  and removed the stray file, after which `check` reported `clean: true`.
- App-id canary (2026-09-02): renaming the `overview.main` surface in
  `AppProductCapabilityRegistry` to `overview.primary` failed
  `testAppCapabilityRegistryCoversEveryImplementationSurface` (unregistered
  surface `overview.main`, unknown surface `overview.primary`, no capability
  for `app.overview.main`) and `testPublishedBundleMatchesThisBuild`
  (`cli-feature-coverage.json` and `app-product-capability-registry.yaml`
  drifted); the registry was restored and both tests passed again.
- Full local gate (`scripts/ci/plan.py … --run-local`): Swift full-parallel
  lane 2366 tests green, the serialized lanes green, App build green;
  `scripts/check-sdd.sh` 0 errors.
- No device, HDC/RockUSB dispatch, real Artifact or hardware evidence is
  involved; the verification covers machine contracts against the
  protected-`main` fact sources only and produces no `REAL_DEVICE_PASS`.

## Residuals

- §14 names `Packages/ArkDeckKit/Tests/Fixtures/CLI/**`; the fixtures live
  under the contract test target's existing `Fixtures/` directory so the same
  `#filePath`-relative lookup every other fixture family uses applies.
- The fixture set covers the parser-level rows of §15.1 (1, 2, 4, 5, 7 and the
  tombstone/lifecycle rows). Process-level rows (file identity, timeout,
  Ctrl-C, daemon disconnect, secrets) stay with `CLIProcessGoldenContractTests`
  and the per-family contract tests; they are not duplicated here.
- The YAML products use a JSON-scalar subset (quoted keys and strings) so a
  YAML reader and a JSON reader see identical values; a consumer that wants
  plain JSON can read `arkdeck commands --output json` instead.
