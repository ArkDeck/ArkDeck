# TASK-OHS-001 implementation run — 2026-08-10

## Conclusion

- Result: `IMPLEMENTING`; no `REAL_DEVICE_PASS` is claimed.
- Base: `origin/main@94a4f33303c6` (approved CHG-2026-057 proposal).
- Candidate Catalog digest:
  `fd68536c229194cb7211a5056a8ede2b83d2c3e7ffea37ed7f34fd41714eaf17`.
- Golden Journey mapping: GJ-2 and GJ-5.

The root defect was that ArkDeck could consume only a HAP signed outside the product. It had no
published signing operation, no secret-safe dispatcher, no verified signed-Artifact lineage, and the
bounded repair route assumed Hvigor's signed filename. The implementation adds one host-only typed
operation on the existing workspace provider and makes the GJ-5 route consume the unsigned build,
sign it through Runtime, verify it, then pass only the published signed lease to `debug.hap@1`.

## Product path exercised by tests

```text
typed workspace.sign-openharmony-hap@1
  -> immutable source Artifact lease admission
  -> closed preset + fresh path/hash/permission checks
  -> descriptor/inode-bound Java and signer JAR
  -> exact two-prompt PTY using Keychain-only secrets
  -> pinned verify-app readback
  -> signed.hap + signing-report.json publication
  -> exact source target/binding inheritance
```

The same signing operation is now inserted by the Harness after build/tests and before
`debug.hap@1`. `HarnessRepairAttempt.buildOutputSigned` is durable and defaults to false for historical
records, so restart/recovery cannot reinterpret an unsigned lease as signed.

## Mechanical verification

| Command | Exit/result |
| --- | --- |
| `sh scripts/check-sdd.sh` | 0; 0 errors, 0 warnings, 121 acceptance IDs |
| `.venv-sdd/bin/python -m unittest discover -s scripts/catalog_gen -p "test_*.py"` | 0; 42/42 passed |
| `.venv-sdd/bin/python scripts/catalog_gen/generate.py --check` | 0; zero drift |
| `swift test --package-path Packages/ArkDeckKit --parallel --num-workers 8` | 0; 1572/1572 passed |
| `swift test --package-path Packages/ArkDeckKit --filter OpenHarmonyLocalSigningContractTests` | 0; 10/10 passed |
| `python3 scripts/check_pr_paths.py --repo-root . --preflight --base-revision origin/main --head-revision HEAD` | 0; `TASK-OHS-001` |
| `git diff --check` | 0 |
| fixture-secret sentinel scan outside `Packages/ArkDeckKit/Tests/**` and build outputs | 0 matches |

The signing tests cover reversible private receipt/secret management, failed-update rollback,
symlink and permission drift, receipt-field drift, JAR drift after plan materialization, unknown and
repeated prompts, secret echo, verify failure/empty profile, typed Runtime publication and binding,
and no-replay recovery. The full Harness Evolution journey includes the new typed signing leg; fake
signer and fake device results remain test evidence only.

## Host and hardware truth

Read-only host diagnostics from the newly built CLI reported:

- `arkdeck signing status --json`: exit 0, `installed=false`, `ready=false`, diagnostic
  `signing preset is not installed`; no Keychain values were requested or read.
- `arkdeck agentd status --json`: exit 0 outside the filesystem sandbox; installed/loaded/ready are
  true, UDS is present, daemon health is `ok`, and the configured HDC path is an explicit absolute
  identity. The running daemon reports Catalog digest
  `4041944428d12e97b1d373cc54d25f9fe8de07937208f9be40a751a9543a759e`, which predates this
  implementation candidate.

No user service was updated or restarted from the unmerged branch. No password, private-key byte,
raw Provision profile, raw HDC, raw hapsigner command, or device identifier was read or written.

Therefore:

| AC | Result |
| --- | --- |
| OHS-AC-1 | PASS — Catalog/schema/generator/Swift/provider closure and exact-list negatives |
| OHS-AC-2 | PASS — install/status/remove, permission/identity drift, and update rollback contracts |
| OHS-AC-3 | PASS (contract) — bounded TTY/Keychain/PTY and secret-absence tests |
| OHS-AC-4 | PASS — lease/ZIP/target/binding admission refuses before dispatch |
| OHS-AC-5 | NOT RUN — real preset secrets are not installed; fake `verify-app` is not substituted |
| OHS-AC-6 | PASS — signed/report Artifacts inherit exact source binding and reject mismatch |
| OHS-AC-7 | PASS — unknown output uses readback only; no signing replay; terminal cleanup is bounded |
| OHS-AC-8 | ENVIRONMENT BLOCKED — current user service is pre-feature and preset is absent |

Real Job/Artifact IDs and a real-device target are intentionally absent because no real signing or
device Job ran. This record must not be upgraded from `IMPLEMENTING` using its simulation coverage.
