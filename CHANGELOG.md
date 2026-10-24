# Changelog

All notable changes to ArkDeck are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project intends to use [Semantic Versioning](https://semver.org/api/v2.0.0.html)
once it has a stable release.

ArkDeck is a 0.1.0 preview. This repository does not publish git tags or
GitHub Releases. History before this file is the git log on `main`.

## [Unreleased]

### Added

- Public contributor entry points: `CONTRIBUTING.md`, `SECURITY.md`,
  `CODE_OF_CONDUCT.md`, GitHub issue and pull request templates, and a root
  `justfile` that wraps the existing build, test, lint, and CI commands.

### Changed

- Renamed non-code trees: `scripts/` to `hack/` (root contract tests in
  `hack/tests/`), `spec/` and `openspec/contracts/` to `api/`, `Catalog/` to
  `catalog/`, and `tests/waterflow-demo/` to `test/fixtures/waterflow-demo/`.
  Package-owned `Fixtures/` directories stay with their projects.
- Archived `PRODUCT-LOOP.md`, `docs/PLAN.md`, `docs/reviews/`, and the
  top-level `evidence/runs/` notes under `docs/archive/`.
- Replaced the 300KB `rust/README.md` log with a short navigation page. The
  log is `docs/rust/development-log.md`.
- Moved `host_loop`, `gj_record`, `manual_ui_flash`, and `windows/spikes` to
  `tools/experiments/`. Removed one-off capture directories under `hack/`
  that no workflow or product code called.
