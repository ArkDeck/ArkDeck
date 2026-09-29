# TASK-XPA-017 — release candidate wall time (macOS, 2026-09-30)

The release-rc workflow's build step took about 11 minutes in run 36590793565 (job 15:31:28, build step
15:31:44, App export 15:40:21, failure at `hdiutil create` 15:41:12), and run 36598594604 repeated the
shape (App archive 16:41→16:47:14, then about 1m45 of DMG create/sign/notarize before its attach
failure). Notarization was not the bottleneck; the build was sequential and the App archive compiled
every SwiftPM package twice. **Nothing was signed, notarized or sent to Apple, no credential was used,
and no workflow was triggered.** Real timings come from the next RC run.

## Measured timeline (run 36590793565, build step)

| Phase | Time | Notes |
| --- | --- | --- |
| Rust helper pair `cargo build --release` | 15:31:47→15:33:26 (1m39) | deps to ~15:32:04, then workspace crates and thin LTO |
| Helper notarize, staple, spctl | ~20 s | inside `build-helpers.sh` |
| ArkForge packager | 15:33:47→15:34:07 (~16 s) | |
| App archive: package resolution | 15:34:10→15:34:44 (34 s) | 11 `git` fetches from GitHub |
| App archive: compile, link, sign | 15:34:44→15:40:18 (~5.5 min) | SwiftPM targets compiled for **both** `x86_64` and `arm64` (e.g. `CCryptoBoringSSL` x86_64 15:35:01→15:36:14, then arm64 15:36:14→15:36:38; NIO, ArkTrace, Citadel pairs throughout) |
| Export, App notarize, staple, spctl | 15:40:18→~15:41:10 | < 1 min |

## What changed

1. **Arm64 only.** `build_macos_release.py` passes `ARCHS=arm64 ONLY_ACTIVE_ARCH=NO` on the
   `xcodebuild archive` command line. The project already sets `ARCHS = arm64` (project and App target,
   Release), yet the log shows every SwiftPM package target built both slices: package targets live in
   their own projects and keep their Release default, and only an invocation-scope setting reaches them
   (`scripts/ci/run-xcodebuild.sh` passes `ARCHS=arm64` for the same reason). Command line rather than
   project settings because the project cannot reach package targets. The App's Mach-O files are checked
   to be thin `arm64` (`lipo -archs`) right after export, before the App is uploaded, and every Mach-O of
   the App, the CLI and ArkForge.bundle again on the mounted DMG (release mode), matching
   `package-rust-helpers.sh` / `check-rust-helpers.py`, which already require thin arm64 helpers.
2. **Concurrency.** The three components (helper pair with its own notarization, ArkForge.bundle, App
   with its notarization) build at once in `build_components`; their inputs and work directories are
   disjoint. Each child runs in its own process group with stdin from `/dev/null`; component output is
   relayed line by line with a `[ArkDeckCLI.app]` / `[ArkForge.bundle]` / `[ArkDeck.app]` prefix, and a
   failing streamed step now reports its last five output lines. The first failure SIGTERMs the other
   components' process groups exactly once (a second signal would interrupt `build-helpers.sh`'s EXIT
   trap, which removes its temporary directories — found by the new cancellation test), steps not yet
   started never start, and all component threads end before the work directory is removed. Failures
   are reported in fixed component order as `<component> failed: <error>`; components stopped only
   because another failed are not reported. The DMG is assembled only when all three succeeded, so
   nothing is published otherwise. Preflight (credentials, identity, versions, ArkForge pin, clean
   checkouts) still runs before any build. Unsigned mode is unchanged (sequential, no build).
3. **Caches** in `release-rc.yml`, all `actions/cache/restore|save` pinned to the SHA the other workflows
   use, `continue-on-error: true`:
   - cargo registry index/cache and git db, key `rust/Cargo.lock` hash + ArkForge pin;
   - `rust/target`, key runner image (`ImageOS-ImageVersion`) + `rustc -vV` digest + `Cargo.lock`;
   - `$RUNNER_TEMP/ArkForge/target`, key image + rustc + ArkForge pin;
   - xcodebuild's SwiftPM clones (`ARKDECK_XCODE_SOURCE_PACKAGES` → `-clonedSourcePackagesDirPath`),
     key the two committed `Package.resolved` files; the archive also gets
     `-onlyUsePackageVersionsFromResolvedFile`, so a stale clone cannot change a package revision.
   Every restore runs before `Install release credentials`; every save runs after
   `Remove release credentials`, only on `success()`, `refs/heads/main`, a newly built RC and an exact
   key miss. Nothing signed is in a cached path: both packagers copy the binaries out of `target/` and
   sign the copies; no crate of this repository reads an `ARKDECK_*` variable at compile time
   (`option_env!`/`env!`/`rustc-env` grep is empty). DerivedData stays fresh in the work directory and
   Xcode compilation caching is not used: its content store would carry objects compiled in an earlier
   run into the signed App, and determinism across runs has not been shown. Cargo reuse is safe with a
   stale target: fingerprints cover toolchain, flags and dependency versions, and the fresh checkout's
   mtimes rebuild the workspace crates every run (mtime restoration was rejected: an older commit rebuilt
   over a newer cached build would look fresh and sign the wrong binary).
4. **Tests.** `test_build_macos_release.py`: notarization order assertions accept the concurrent helper and
   App submissions; the archive must carry `ARCHS=arm64`, `ONLY_ACTIVE_ARCH=NO`,
   `-onlyUsePackageVersionsFromResolvedFile` and a DerivedData under the work directory; lipo checks of
   the exported App before its upload and of six mounted Mach-Os. New: a rendezvous test (helper
   `cargo build` and App `xcodebuild archive` each wait for the other to start; sequential would time
   out), a failing Rust build and a failing App archive each publish nothing, never assemble or submit the
   DMG and name only their component, the first failure stops a 90 s helper build within the test
   deadline without leaking temporary directories, a universal App is refused before its upload, the
   SwiftPM directory reaches the archive, and a relative one is refused before any build.
   `test_agent_pr_workflow.py` (`_validate_release_rc_caches`) requires pinned restore/save actions
   only, no secret or `env:` in a cache step, no cached path naming credentials, a keychain, `.p12`/`.p8`,
   a profile, the RC output, DerivedData, an archive, an export or a compilation cache, restores before the
   credential install, saves after the cleanup with the main/success/new-RC condition, and saves only
   restored paths; 13 new mutations.
5. **Docs.** `docs/release/macos-install.md` describes the caches, the concurrent build, arm64-only and the
   new `ARKDECK_XCODE_SOURCE_PACKAGES`.

## Expected savings (to be confirmed by the next RC run)

| Item | Expected | Reasoning |
| --- | --- | --- |
| Arm64-only archive | ~2–2.5 min | about half the package compile work was the unused x86_64 slice; the 3-vCPU runner was CPU bound, so ~5.5 min of compile should drop to ~3 min |
| Concurrent components | ~2.5 min | helper build + notarize (~2 min) and ArkForge (~20 s) move off the critical path, which becomes the App lane; they share the CPU with the archive's first minutes, so some of that time comes back as contention |
| Overlapping notarizations | up to the helper notarization time | the helper and App submissions wait on Apple at the same time (~20 s in these runs, possibly much longer on a slow day) |
| SwiftPM clones cache | ~30 s | 34 s of package fetches measured; a warm local resolve took 1.7 s |
| Cargo caches | ~20 s of CPU, little wall time | the helper lane is no longer critical, but a warm target removes ~20 s of dependency compiles competing with the archive; the fetch steps took ~2 s |
| Total | build step ~11 min → ~5.5–6.5 min | App lane ≈ 0.1 min resolve + ~3 min compile + export + ~1 min notarize, then ~1.75 min DMG |

## Local targeted checks

| Command | Exit | Result |
| --- | --- | --- |
| `python3 scripts/release/test_build_macos_release.py` | 0 | 35 tests OK (7 new; on top of #2324, whose 2 attach tests also pass) |
| selected new concurrency/failure tests, 3 repeats | 0 | OK each time |
| `python3 scripts/test_agent_pr_workflow.py` | 0 | 17 tests OK (13 new mutation subtests) |
| PyYAML `safe_load` of `release-rc.yml` (`.venv-sdd`) | 0 | 22 steps, 4 restores before the credential install, 4 saves after the summary |
| `bash -n` on `build-helpers.sh`, `package-rust-helpers.sh` | 0 | unchanged, syntax OK |
| `xcodebuild -resolvePackageDependencies -onlyUsePackageVersionsFromResolvedFile -clonedSourcePackagesDirPath <scratch>` (Xcode 27.0) | 0 | cold resolve of the 11 pinned packages; warm rerun 1.7 s with no fetch |
| `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |

Not run: the workflow itself (maintainer `release` environment), a real archive (signing identity).

## CI

PR and run ids are recorded by the follow-up that records this PR's CI.
