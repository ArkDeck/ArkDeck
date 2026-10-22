# TASK-ATI-001 reviewed ArkTrace profile evidence

- Evidence class: real macOS arm64 production daemon-private generation and process path; not a
  fake or simulation.
- ArkDeck implementation base: `26de01e100d3fcbde4dfefeb20cf47e2a7b6ae9b` plus the
  committed `CHG-2026-058` vertical implementation under review. Its classification-independent
  worktree identity is `ff178a2eabb07dd35a893c30ae0415ac31c74f06260d5a27a4249c832679c259`:
  the NUL-safe union from `git ls-files --cached --others --exclude-standard`, globally byte-sorted
  with `LC_ALL=C`, hashes one `executableBit byteCount sha256 path` line per file and excludes only
  this self-referential evidence file. Moving identical bytes from untracked to staged or committed
  therefore leaves this identity unchanged. For build-time audit, the base-relative tracked binary
  diff SHA-256, excluding only this self-referential evidence file, is
  `2f401664d2beed5ac31b9ad5574e496f390d45a74a6fbca2b645db475a6d819a` and the separately
  sorted untracked projection SHA-256 is
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.

  The exact zsh commands used at repository root are below. Duplicate paths,
  CR/LF-bearing paths, symlinks and non-regular files fail closed; every emitted record has one
  trailing LF. `executableBit` is exactly `x` when the owner execute bit is set and `-` otherwise.

  ```zsh
  set -o pipefail
  evidence_path='evidence/runs/TASK-ATI-001/2026-08-14-reviewed-arktrace-profile.md'
  project_tree() {
    local path previous='' executable byte_count sha
    while IFS= read -r -d '' path; do
      [[ "$path" != "$evidence_path" ]] || continue
      [[ -z "$previous" || "$path" != "$previous" ]] || return 65
      [[ "$path" != *$'\n'* && "$path" != *$'\r'* && -f "$path" && ! -L "$path" ]] || return 65
      executable='-'; [[ -x "$path" ]] && executable='x'
      byte_count=$(/usr/bin/stat -f '%z' "$path") || return
      sha=$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}') || return
      /usr/bin/printf '%s %s %s %s\n' "$executable" "$byte_count" "$sha" "$path"
      previous="$path"
    done
  }
  git ls-files --cached --others --exclude-standard -z \
    | LC_ALL=C sort -z | project_tree | /usr/bin/shasum -a 256

  git diff --binary --no-ext-diff origin/main...HEAD -- . \
    ":(exclude)$evidence_path" | /usr/bin/shasum -a 256
  git ls-files --others --exclude-standard -z | LC_ALL=C sort -z \
    | while IFS= read -r -d '' path; do
        [[ "$path" != "$evidence_path" ]] || continue
        [[ "$path" != *$'\n'* && "$path" != *$'\r'* && -f "$path" && ! -L "$path" ]] || exit 65
        mode=$(/usr/bin/stat -f '%Lp' "$path") || exit
        byte_count=$(/usr/bin/stat -f '%z' "$path") || exit
        sha=$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}') || exit
        /usr/bin/printf '%s %s %s %s\n' "$mode" "$byte_count" "$sha" "$path"
      done | /usr/bin/shasum -a 256
  ```
- ArkDeck debug test binary SHA-256:
  `7fc97bc8947e9c792f53f2b47d6a11f0d8039782055bfe4ffd3b680fad647801`.
- Reviewed ArkTrace distribution evidence: source revision
  `cddcd508757db3ebc0f3c7fcad4458076ed07c57`, source tree SHA-256
  `778c5ad63371b89dd4f5454ea5c71db8bff89f8cb74c7dc397d773baaa8b98d4`, and tracked
  `phase5-cli-distribution.json` SHA-256
  `b0532c580fdbd42e02b1d231d5390b8093e2f5fc4f70b88fbb0d2d9f1e527d8b`.
- Reviewed notarized archive: `ArkTraceCLI-0.1.0-20260814T105423Z.zip`, 5,076,367 bytes,
  SHA-256 `ad5cd371bf52ad632ac58aa78594cdfb4501259398a3c54df4b9ec8a36955d7a`.
- Reviewed ArkTrace distribution manifest SHA-256:
  `443a04a711b6dfc6866e97d4177301e6d5901d8abe2e324d525f156b5bfbf25b`.
- Reviewed signed App tree SHA-256:
  `7f3e50dbedcbac160d51da707070124ae8c8a1fa2b71044ca7df77c4d4649758`;
  resource tree SHA-256:
  `3f79f263bfca14c80407e7d1f9d66a4bed3a5ddf5c6277c6071ba529bc6c9673`.
- ArkTrace tool SHA-256:
  `0c552cbaac49d2ed641e999cb01163b3aa8bac5ce2015d52ef7caf552dabdc65`.
- ArkTrace App CodeDirectory hash: `dc77f43dc774a6eb489241bc8424db736570a035`.
- Bundled TraceStreamer SHA-256:
  `2e8316265f8fdc027614d81c7d71646a0eb7dfadffbb2503e13ee66287f937e5`.
- Bundled TraceStreamer CodeDirectory hash: `9b4685ac5e54a930f434f4c5eb0b5536d844dae3`.
- Developer ID Team `8AQTYW5FKR`; certificate SHA-1
  `38E3B7650DF0CE1DEC0CC8C403614AA0C38B0B4C`; Apple notarization submission
  `bf933f7e-9f67-443e-9f1c-34669837d7ac` was `Accepted`, stapled, and passed Gatekeeper.
- Input zlib trace SHA-256:
  `eb196eeb30c6b959c23d5e18d159ec946ba664ee8d9bc6f1acc32947b4ff5cfe`.
- Fixed invocation: `summary --json --no-cache --timeout-ms 30000 --max-rows 1000
  --max-events 10000 --max-output-bytes 8388608 <one-artifact-path-token>`.
- Production loader copied the reviewed signed distribution through retained descriptors into its
  owner-private tree-SHA generation, revalidated the copied App/signature/notary/tree identities,
  and returned only executable/pin paths beneath that generation.
- `ProductionArkTraceDoctorProbe` over the copied private generation: success; exact nine checks
  present and `ok`, stderr empty, stdout complete.
- `DescriptorBoundProcessDispatcher` result: success through the suspended canonical-path,
  kernel-mapped device/inode verification boundary; no shell, PATH selection, HDC or GUI route.
- ArkTrace JSON 1.0 summary validation result: success; source/tool/parser identities above were
  rebound to the immutable invocation.
- Exact derived output: 2,226 bytes; SHA-256
  `3370c46ff96dfd5c4c62bea3f9765bd38cd48f8c39abc814de8b7cb3bc4622c4`.
- Production replay started `2026-08-14T23:51:26Z` and completed `2026-08-14T23:51:29Z`.
  The command was `CI=true swift test --package-path Packages/ArkDeckKit --filter
  ArkTraceSummaryAnalyzerContractTests`
  with `ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR` and `ARKDECK_REVIEWED_ARKTRACE_FIXTURE` bound to
  the reviewed identities above. The two absolute path values are deliberately redacted.
- Production replay result: 16 tests executed, 0 skips, 0 failures, 0 unexpected failures. The
  signed-distribution test asserted exact source byte/hash binding, tool/parser identity, empty
  stderr, derived byte/hash identity, and the final `ProviderSemanticOutcome.verified` verdict;
  the surrounding contract cases also covered the closed JSON/privacy boundary and the
  descriptor-bound snapshot/source leases used by that production path.
- Frozen-worktree validation: `scripts/ci/plan.py --repo-root . --base-revision origin/main
  --head-revision HEAD --merge-base --include-worktree --run-local` exited 0. It covered 17 plan
  tests, 8 Agent PR workflow tests, SDD with 121 acceptance IDs and no errors/warnings, 42 catalog
  tests, 10 SwiftPM lane tests, the full 1,638-test Swift lane, and the Xcode App/UI-test
  `build-for-testing` lane.
- Independent Release XCTest replay used the same frozen bytes with Swift Testing disabled because
  this package has no Swift Testing suites: 1,638 tests executed, 13 explicitly gated tests
  skipped, 0 failures, 0 unexpected failures, exit 0. The reviewed signed-distribution environment
  was present, so the production replay test ran rather than contributing another default skip.
- Absolute source, cache, distribution and executable paths are intentionally omitted.

The independent Large Trace gate remains deferred and is not claimed by this evidence.
