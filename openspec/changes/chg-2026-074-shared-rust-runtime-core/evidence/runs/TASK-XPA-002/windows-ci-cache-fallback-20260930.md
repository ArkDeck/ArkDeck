# Rust CI cache: PR-only fallback and per-image retention — 2026-09-30

- Task: TASK-XPA-002 (CI slice CI2, PR 1 of 2)
- Authority: the maintainer approved options B, C and E of
  `windows-ci-speed-analysis-20260930.md` on 2026-09-30. This PR is B and C;
  E is the separate `agent/ci-skip-empty-harnesses-20260930` PR.
- Base: stacked on #2364 (`06b10dc9`, `CARGO_INCREMENTAL=0` in the key), so
  the key below already separates incremental and non-incremental products.
- Author: Repo Agent on the maintainer's Windows 11 x64 reference host.

## Why

The analysis found the macOS `Rust workspace (xcode-27)` job on the critical
path of every successful Swift CI run, 13.7 min median on a cache miss against
9.5 on a hit. PR runs hit main's cache 20-31% of the time, for three reasons:
the compatibility key hashed every `Cargo.toml` and the lockfile with no
fallback (30 of 34 Windows workspace misses were manifest sets main had never
saved), two runner images served at once, and retention kept one entry per
host and job so the second image's entry, and the entry older PRs matched,
were deleted after every main run.

## Design

### B. PR-only broader restore fallback

`rust/scripts/ci-workspace.py key` now builds the key in two layers:

```
arkdeck-rust-build-v3-<host>-image-<ImageVersion>-<toolchain digest>-<manifest digest>-<UTC day>
\______________________ fallback ______________________________/
\______________________________ prefix (exact compatibility) _______________/
```

- toolchain digest: `rustc -vV`, `cargo -V`, `ImageVersion`, the absolute
  cache root (so the job and, with the actions/cache version, the archive
  format and path), `RUSTFLAGS`, `CARGO_ENCODED_RUSTFLAGS`, `RUSTC_WRAPPER`,
  `CARGO_INCREMENTAL`, `rust/rust-toolchain.toml`;
- manifest digest: every `Cargo.toml` under `rust/` and `rust/Cargo.lock`.

Both digests are over the same inputs the v2 key hashed; nothing left the key.
The step now also outputs `fallback`. `rust-ci.yml`, in both native jobs:

```yaml
restore-keys: |
  ${{ steps.rust-cache-key.outputs.prefix }}
  ${{ github.ref != 'refs/heads/main' && steps.rust-cache-key.outputs.fallback || '' }}
```

On protected main the second line is empty (actions/cache drops empty lines),
so main restores only an exact compatibility match, as before, and what it
saves never carries another manifest set's products. A run off main tries the
exact prefix first and then main's newest entry for the same host, image,
toolchain, flags and cache root. Those runs never save (the save step stays
`success() && github.ref == 'refs/heads/main' && cache-hit != 'true'`), so the
stale products a fallback restore brings stay in that runner. Cargo's
fingerprints decide what to rebuild, the same as after any partial restore.

`scripts/test_agent_pr_workflow.py` replaces the pin "fallback must retain
every compatibility dimension" with the narrower invariant: exactly the two
restore lines above, the fallback referenced once and only behind the
`github.ref != 'refs/heads/main'` guard, exactly one `actions/cache/save` per
native job, main-only, and no combined `actions/cache` action. New mutation
cases (`test_rust_build_fallback_is_pr_only_and_prs_never_save`): the fallback
unguarded, the guard inverted or on another ref, the fallback before the exact
prefix, an extra unguarded fallback line, the fallback as the saved key, the
save's main condition removed, a second save step without it, and the
combined restore-and-save action. `rust/scripts/test_ci_execution.py`
(`test_fallback_keeps_host_toolchain_image_flags_and_root_but_not_manifests`)
proves the fallback survives lockfile and manifest churn and still changes
with image, host, `RUSTFLAGS`, `CARGO_INCREMENTAL`, compiler, cache root and
toolchain file, and that an image string cannot forge a separator.

### C. Retention per image, within a byte budget

`scripts/ci/retain-rust-caches.py` parses the v3 key (image in clear) and, per
`(host, actions/cache version)` group as before:

1. keeps the newest entry (always, as before, even over the budget);
2. keeps the newest entry of **one** other image (never the same image twice,
   never a third image, never a v1/v2 key, which names no image);
3. admits those other-image entries newest first only while all retained main
   Rust entries fit `RUST_BUDGET_BYTES` = 5.0 GB; the rest are deleted.

Chosen over "newest two per host" because two entries of the same image would
cost the same space and serve only PRs branched before a manifest change,
which B now serves from the newest entry anyway.

Budget. At 07:08 UTC on 2026-09-30 (read-only `gh api .../actions/caches`)
one entry per host and job was 3.07 GiB (Windows 708 + 169 MiB, Linux 848 +
161, macOS 921 + 267), and the newest SwiftPM and Xcode entries 870 + 857 MiB.
With the budget the steady state after a retention pass is at most 5.0 GB of
Rust plus about 1.8 GB of SwiftPM/Xcode, leaving about 3.2 GB for one main
run's fresh saves before the next pass. SwiftPM, Xcode and policy-tool entries
are neither counted nor deleted. (The listing also showed three
generations each of SwiftPM and Xcode entries, 5.2 GB, because those families
have no retention; that is outside this PR and unchanged by it.)

Tests (`CacheRetentionTests`): the v2 cases unchanged; second-image keep, third
image and older same-image entries removed, same image never twice, v2 never
the second entry; budget admission newest first, primaries kept over budget,
other families neither counted nor removed.

## Expected savings (not yet measured)

From the analysis' medians:

| job | today, miss / hit | expected on a PR whose manifests main has not saved |
| --- | ---: | --- |
| Rust workspace (xcode-27), critical path | 13.7 / 9.5 min | close to the hit figure: **about 4 min** off, so Swift CI wall clock about 4 min shorter on such PRs |
| Rust workspace (windows-latest) | 4.44 / 3.03 | about 1.4 min |
| Rust contract parity (windows-latest) | 2.62 / 2.02 | about 0.6 min |
| Linux jobs | 1.9 / 1.4 | about 0.5 min |

A fallback restore is a partial hit: a PR that changes the lockfile rebuilds
the changed dependencies and their dependents, a PR that only adds a test
target rebuilds the workspace crates, as a hit does. C adds the jobs on the
second image (12 of 51 Windows workspace jobs, 3 hits) and the 4 of 34 misses
whose entry retention had deleted.

What will be measured, and when: the key format changes (v2 to v3), so this
PR's own run and the first main run per host after merge are cold; the effect
shows from the second main run onwards. The CI section below and a follow-up
record the PR run and the first PR runs after merge (hit/miss from the restore
step's `Cache restored from key:` line, as in the analysis).

## Local targeted checks

On the Windows 11 x64 reference host, Python `D:\src\ArkDeck\.venv-sdd`:

| command | exit | note |
| --- | ---: | --- |
| `python scripts/test_agent_pr_workflow.py` (`PYTHONUTF8=1`) | 0 | 18 tests; without `PYTHONUTF8` one unrelated test fails reading a workflow as GBK on this host's locale |
| `python rust/scripts/test_ci_execution.py WorkspaceCacheTests CacheRetentionTests` | 1 | new and changed cache/retention tests pass; `test_restored_git_authority_is_replaced_without_inheriting_credentials_or_environment` fails identically on unmodified main (git-ai wrapper on this host; the suite runs on Ubuntu in CI). Temporary-directory cleanup intermittently fails on this host with `WinError 145/32` on `checkout/.git/ai` (the git-ai hook writing into the fixture repository); a rerun passes |
| `python scripts/ci/test_plan.py` | 0 | 40 tests |
| `python scripts/ci/retain-rust-caches.py` (no `--apply`, read-only listing) | 0 | removes nothing from the current v2 entries |
| `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |

## CI

To be recorded by the follow-up (PR number, run id, restore-step outcome per
job).
