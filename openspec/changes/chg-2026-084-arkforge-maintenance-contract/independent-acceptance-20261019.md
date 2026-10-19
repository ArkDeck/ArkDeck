# Independent Flash maintenance acceptance — 2026-10-19

Both maintenance entry points now have independent real-device results on the
Windows Runtime with a connected DAYU200 Normal/HDC target. Original-ramdisk
restoration and a subsequent standalone verification each returned exit 0. The
nine-partition verification retains its truthful partial result, exit 9. The
earlier recommission result is not used as acceptance for either entry.

The Runtime was built from clean protected-main source
`80d7f9ecd3e70888e3be62173856f6c595096c42`. All three new maintenance Jobs used
the current Catalog:
`88c20a2c364b87ae6e7327edfd1b3bffecaeeff2e67f71dbd6aaa43db74ec195`.

| Typed operation and source | Actual maintenance result | Runtime publication |
| --- | --- | --- |
| `flash.verify@1`, ordinary nine-partition Flash | Exit 9: eight full hashes matched, userdata skipped, zero failed | Own succeeded Job, published Session generation 58 |
| `flash.restore-boot-loop@1`, same ordinary source and original-image lease | Exit 0: original ramdisk restored and its complete 4 MiB independently hashed, zero skipped or failed | Own succeeded Job, published Session generation 59 |
| `flash.verify@1`, the new restoration Job | Exit 0: complete original ramdisk hash matched, zero skipped or failed | Own succeeded Job, published Session generation 60 |

The first verification's userdata outcome is `typedSkip`, reason
`mounted-writable-after-boot`; it has no observed hash or verification strength.
It is not full nine-partition verification. Both ramdisk results cover exactly
4,194,304 bytes starting at byte 121,634,816, with `fullHash` and matching expected
and observed SHA-256:
`bdd1f4eacbe545f5a553b529980bc487723d37554148058dd551c241abf86de4`.
This run does not establish induced-boot-loop, Loader or MaskRom fault coverage.

## Published fixes and source preparation

The initial installed Runtime omitted both maintenance references from its Flash
availability matcher. [PR #2673](https://github.com/ArkDeck/ArkDeck/pull/2673)
repaired discovery while retaining the shared admission owners and qualification
checks. Its failing regression was reproduced before four availability tests
passed. Verification still uses the default read-only policy.

The separately reviewed policy in
[PR #2675](https://github.com/ArkDeck/ArkDeck/pull/2675) was published as
`f67e9919f87c9cb25d285c6317cbeb0e1b1cdf5b`. It enables only the existing exact
original-ramdisk Runtime policy. Destructive effect, fresh facts, source/Artifact
checks, one-use reservation and no-replay requirements remain enforced.

After explicit approval of both the policy and the userdata-overwrite scope, one
ordinary primary Flash wrote the original nine-partition bundle through the typed
Runtime operation. That succeeded source uses the same current Catalog. The
maintenance runs reuse it; no second source Flash or recommission allocation was
used. Fresh Runtime materialization accepted the retained Runtime-issued original
image lease. An old receipt was only an opaque input reference, not a fresh fact.

The first standalone verification exposed two further production defects:
`job.result` and `job.evidence` rejected maintenance Jobs, and maintenance omitted
the Job-local observation required for Session publication.
[PR #2676](https://github.com/ArkDeck/ArkDeck/pull/2676) repairs the reader and
records a fresh machine observation before capability consumption, retaining that
first observation through later readback. Missing or mismatched observations fail
closed. No Core vocabulary, Catalog digest or publication requirement was relaxed.
After publication, the old terminal partial result was readable without replay.

The source Flash's older Session remains failed because its postflight observation
postdates capability admission. The first verification's older Session remains
failed because it lacks an observation. Their immutable records were not backfilled
or relabeled. The three new maintenance Jobs above have their own published
Sessions and do not rely on either failed Session publication.

## Runtime evidence and authority

Every new run was submitted exactly once using `arkdeck agent run` with its fresh
reviewed plan digest. The initial CLI waits returned `clientTimeout` (75); passive
`agent.status` queries subsequently proved those same Jobs succeeded with
`outcomeUnknown: false`. No uncertain request was replayed. Public `job.result`
and `job.evidence` agree; required Artifacts are present and have no blockers.
Each Session has its own Runtime-issued manifest hash and catalog generation.

Each published `maintenance-result.json` was fetched through typed `artifact.read`.
The complete bytes, byte count and Artifact-index SHA-256 were checked locally:

| Result | Bytes | Report SHA-256 |
| --- | ---: | --- |
| Nine-partition verify | 3,843 | `725687f206f4df6cc83f13adda88e60a8f33b67ee9ef90ae16c283f7e27b3f3a` |
| Ramdisk restoration | 1,047 | `3c266d049d938f186418572faf997c3c95bf01853017749e9cc03ecc1b0c95bb` |
| Independent post-restoration verify | 752 | `b12c1b284c9cc6592848dde428e4a6a53a2d8e222ebe4da03753c08f9f7bc021` |

Both entry points independently refused an ineligible recovered recommission
source on the final Runtime: `admissionDenied`, `phase: preAdmission`,
`newDispatchCount: 0`. The restoration refusal retained its own stopped record.
Neither refusal is counted as a successful maintenance result.

The final read-only authority audit found exactly one new capability: the
Runtime-owned restoration capability, matching the exact inputs, plan, binding,
physical identity and original Artifact. It was consumed once, has zero remaining
uses, and has one confirmed succeeded outcome. Its machine observation predates
admission. Neither standalone verification consumed a capability. All 132 original
Job files, 32 original capability records, both recommission allocations and the
successful source's three frozen files remained unchanged. No Agent created or
modified Runtime authority, trusted facts, coverage declarations or hardware
evidence records.

Final typed service, health, target and HDC status reads all succeeded; the signed
Runtime is ready on the same Catalog and binding revision 2. Original Runtime
responses and Artifact bytes stay local under
`D:/src/ArkDeck-wt/tools/flash-maintenance-results-20261019-80d7f9ecd3e7/`.
This document contains only the scoped result summary and hashes, without device
identifiers, connect keys, account paths or raw hardware records.

## Local targeted checks

- Result/publication regression: baseline exit 101; final maintenance integration
  filter exit 0, seven tests. Covers both public readers, published Sessions,
  advancing-clock pre-consumption observation, missing/mismatched observation
  refusal, partial exit 9, exact ramdisk scope, one consumption and immutable
  source history. Logs: `D:/src/ArkDeck-wt/tools/flash-maintenance-results-red-20261019.log`
  and `flash-maintenance-results-audit-clock-20261019.log` in the same directory.
- Hoststore, agentd and soak library checks: exit 0; respectively 426, three and
  three tests passed, with five existing hoststore ignores. Clippy for those
  crates and all targets with `-D warnings`: exit 0. Logs in that directory:
  `flash-maintenance-results-libs-20261019.log` and
  `flash-maintenance-results-clippy-20261019.log`.
- An unfiltered local three-crate integration attempt exited 101: two daemon
  ownership checks conflicted with the installed acceptance Runtime and five
  integrations require their historical Catalog views. Assertions were retained;
  all corresponding isolated CI workspace/parity lanes passed. Log:
  `flash-maintenance-results-crates-20261019.log`.
- `run-cargo.py fmt --all --check` hit Windows OS error 206. The equivalent
  batched check of all 358 workspace target roots passed; logs
  `flash-maintenance-results-fmt-all-20261019.log` and
  `flash-maintenance-results-fmt-batched-20261019.log`.
- Clean-main signed Runtime package build: exit 0, 171.84 seconds. Versioned
  installation verified 365 files and three valid executable signatures.
  Local log: `vendor-sn-runtime-release-80d7f9ecd3e7-maintenance-results.log`.
- Documentation follow-up: `sh scripts/check-sdd.sh`, exit 0, zero errors and
  warnings; log `flash-maintenance-acceptance-docs-sdd-final-20261019.log` in the same
  local tools directory. `git diff --check`: exit 0. Swift, App UI checks and a
  local unified gate were not rerun for this documentation-only follow-up.

## CI

- Discovery [PR #2673](https://github.com/ArkDeck/ArkDeck/pull/2673), final head
  `bfad43b9b7573dc57a73c6fe8897154fd8e946de`: required
  [SDD Guard 39150465613](https://github.com/ArkDeck/ArkDeck/actions/runs/39150465613)
  and [Swift CI 39146136060](https://github.com/ArkDeck/ArkDeck/actions/runs/39146136060)
  passed, including all six Rust workspace/parity lanes.
- Policy [PR #2675](https://github.com/ArkDeck/ArkDeck/pull/2675), final head
  `d0c19d3738d199a0d11e27a3b71632bbcb422a79`: required
  [SDD Guard 39161411725](https://github.com/ArkDeck/ArkDeck/actions/runs/39161411725)
  and [Swift CI 39156057942](https://github.com/ArkDeck/ArkDeck/actions/runs/39156057942)
  passed, including all six Rust lanes, Swift, App and Windows client checks.
- Results [PR #2676](https://github.com/ArkDeck/ArkDeck/pull/2676), final head
  `15e29520e5435f254850f9b19cd01d18b306c16e`: required
  [SDD Guard 39185625753](https://github.com/ArkDeck/ArkDeck/actions/runs/39185625753)
  and [Swift CI 39185556123](https://github.com/ArkDeck/ArkDeck/actions/runs/39185556123)
  passed, including all six Rust lanes and the host-independent checks. The seven
  maintenance tests actually ran in the Windows and macOS workspace lanes.
  Swift/App/client lanes were skipped by the Rust-only selection.

The protected-main required contexts were read back as `guard` and `swift` before
publication. CI is software validation; the independent device results above come
from the published Runtime's actual Jobs and Artifacts.
