# TASK-ATI-002 reviewed ArkTrace analysis evidence

- Evidence class: real macOS arm64 production daemon-private generation and process path; no
  fake or simulation is counted as platform trust.
- ArkDeck protected-main base: `528b521c7a6ace44e225ffbc3d1e1797b9c1a54f` (PR #1309).
- Candidate worktree identity, excluding only this self-referential evidence file:
  `8b756c32204d237f8d733483a4b1a913e5a9b6292f3999bf1c540aedb61deb43`.
  The projection is classification-independent for this task: files that are initially untracked
  are explicitly added to the cached path set, byte-sorted and deduplicated, so staging or
  committing identical bytes does not change the identity. The unrelated local
  `chg-2026-059-arkdeck-arkforge-authority` draft is not part of this task or projection.

  ```zsh
  set -o pipefail
  evidence_file='evidence/runs/TASK-ATI-002/2026-08-15-reviewed-arktrace-analysis.md'
  {
    /usr/bin/git ls-files --cached -z
    /usr/bin/printf '%s\0' \
      'Catalog/operations/analyzer.analyze-trace.v1.json' \
      'Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AnalyzerProvider/ArkTraceAnalysisEnvelopeValidator.swift' \
      'Packages/ArkDeckKit/Tests/ArkDeckContractTests/ArkTraceAnalysisAnalyzerContractTests.swift' \
      'openspec/changes/chg-2026-060-arktrace-deep-analysis/proposal.md' \
      'openspec/changes/chg-2026-060-arktrace-deep-analysis/design.md' \
      'openspec/changes/chg-2026-060-arktrace-deep-analysis/tasks.md' \
      'openspec/changes/chg-2026-060-arktrace-deep-analysis/verification.md' \
      "$evidence_file"
  } | LC_ALL=C /usr/bin/sort -zu \
    | while IFS= read -r -d '' candidate_path; do
        [[ "$candidate_path" != "$evidence_file" ]] || continue
        [[ "$candidate_path" != *$'\n'* && "$candidate_path" != *$'\r'* \
          && -f "$candidate_path" && ! -L "$candidate_path" ]] || exit 65
        executable_mark='-'; [[ -x "$candidate_path" ]] && executable_mark='x'
        byte_count=$(/usr/bin/stat -f '%z' "$candidate_path") || exit
        sha=$(/usr/bin/shasum -a 256 "$candidate_path" | /usr/bin/awk '{print $1}') || exit
        /usr/bin/printf '%s %s %s %s\n' \
          "$executable_mark" "$byte_count" "$sha" "$candidate_path"
      done | /usr/bin/shasum -a 256
  ```

## Contract identity

- Existing `analyzer.summarize-trace.v1.json` SHA-256 remains
  `b41b4c43d8d44a88d43dd5da1d87e5297d00dfa4fc22cbb8187fcd64fcdc5e31`.
- New `analyzer.analyze-trace.v1.json` SHA-256 is
  `4755f7221a0e7c21e8209273083bcbeb3b77b7bc61cafe9462d7a75ff3fe8835`.
- ArkDeck debug test binary SHA-256:
  `0ae95c3cafd8ec2f94ddef42d0bc1ecbf0f86d46a07ae7dc9002ad14bd7526f7`.

## Reviewed ArkTrace distribution

- Tracked ArkTrace distribution evidence SHA-256:
  `b0532c580fdbd42e02b1d231d5390b8093e2f5fc4f70b88fbb0d2d9f1e527d8b`.
- Reviewed notarized archive: `ArkTraceCLI-0.1.0-20260814T105423Z.zip`, 5,076,367
  bytes, SHA-256 `ad5cd371bf52ad632ac58aa78594cdfb4501259398a3c54df4b9ec8a36955d7a`.
- ArkTrace source revision `cddcd508757db3ebc0f3c7fcad4458076ed07c57`; source-tree SHA-256
  `778c5ad63371b89dd4f5454ea5c71db8bff89f8cb74c7dc397d773baaa8b98d4`.
- Distribution manifest SHA-256:
  `443a04a711b6dfc6866e97d4177301e6d5901d8abe2e324d525f156b5bfbf25b`.
- Final App tree SHA-256:
  `7f3e50dbedcbac160d51da707070124ae8c8a1fa2b71044ca7df77c4d4649758`;
  resource tree SHA-256:
  `3f79f263bfca14c80407e7d1f9d66a4bed3a5ddf5c6277c6071ba529bc6c9673`.
- Tool SHA-256 `0c552cbaac49d2ed641e999cb01163b3aa8bac5ce2015d52ef7caf552dabdc65`;
  bundled TraceStreamer SHA-256
  `2e8316265f8fdc027614d81c7d71646a0eb7dfadffbb2503e13ee66287f937e5`.
- Developer ID Team `8AQTYW5FKR`; certificate SHA-1
  `38E3B7650DF0CE1DEC0CC8C403614AA0C38B0B4C`; Apple submission
  `bf933f7e-9f67-443e-9f1c-34669837d7ac` is Accepted, stapled and Gatekeeper
  accepted. The exact unpacked distribution passed the Phase 5 full verifier, nested/outer
  `codesign --deep --strict`, `stapler validate` and `spctl` immediately before replay.
- Input zlib trace SHA-256:
  `eb196eeb30c6b959c23d5e18d159ec946ba664ee8d9bc6f1acc32947b4ff5cfe`.

## Production replay

- The production loader copied the reviewed signed distribution through retained descriptors into
  an owner-private tree-SHA generation, revalidated the copied App/signature/notary/tree identity,
  and returned one shared pin set for `trace-summary@1` and `trace-analysis@1`.
- `ProductionArkTraceDoctorProbe` passed before dispatch. The process route was
  `DescriptorBoundProcessDispatcher` with the immutable source lease; no shell, PATH selection,
  GUI, HDC or caller-selected executable was involved.
- Fixed review range: `[10,100,000,000, 10,300,000,000)` ns; limits were timeout 30,000 ms,
  maxRows 10,000, maxEvents 10,000 and maxOutputBytes 8,388,608. Analysis limit was 10.
- Exact outputs:
  - summary: 2,226 bytes, SHA-256
    `3370c46ff96dfd5c4c62bea3f9765bd38cd48f8c39abc814de8b7cb3bc4622c4`;
  - context: 46,758 bytes, SHA-256
    `dc6ce18e4049311371cb8c3a71d17e0ad4ceec28908afe11606540e2657d084e`;
  - range analysis: 8,719 bytes, SHA-256
    `86f99a5be63a00e73f07b7e4b5214e215a1516ef6ef31d04df7ab682d67dfc73`.
- The context result contained real retained slices; range analysis contained real long-slice and
  hot-interval rows. All three stderr streams were empty and the closed validators rebound source,
  request, tool and parser identity before returning `ProviderSemanticOutcome.verified`.
- Replay started `2026-08-15T02:40:30Z` and completed `2026-08-15T02:40:33Z`.
  Absolute source, cache, descriptor, distribution and executable paths are intentionally omitted.

## Frozen verification

- Catalog generator unit tests: 42 passed; generated output check: zero drift.
- `ArkTraceAnalysisAnalyzerContractTests`: 8 passed, 0 failed.
- `ArkTraceSummaryAnalyzerContractTests`: 16 passed, 0 failed, including the reviewed production
  replay and existing summary compatibility/lifecycle cases.
- Path-aware local CI passed: plan tests 17/17, Agent PR workflow 8/8, SDD 121 acceptance IDs with
  0 errors/0 warnings, Catalog 42/42, SwiftPM lane tests 10/10, full Swift lane enumerated 1,646
  tests and exited 0, and Xcode App/UI-test `build-for-testing` succeeded.

The change remains `proposed`/`in-progress` until maintainer review and merge. Independent Large
Trace and real capture Artifact gates remain deferred and are not claimed by this evidence.
