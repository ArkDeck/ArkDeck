# Verification — CHG-2026-057

> Change:CHG-2026-057-openharmony-local-signing@r1
> Status:planned；proposal merge 只批准 scope，不代表实现或真实硬件通过

## Environment

- macOS 14+ 登录用户 LaunchAgent；Swift 6 / ArkDeckKit；当前 protected-main Catalog digest。
- operator 显式安装的 canonical absolute Java executable 与 OpenHarmony SDK
  `hap-sign-tool.jar`，二者及 keystore/certificate/profile 均有 fresh SHA-256。
- 一份真实 unsigned OpenHarmony HAP；OHS-AC-8 另需已接管且信任完成的 OpenHarmony 真机。
- 口令只存在于测试 secret double 或当前用户 Keychain，不进入仓库 evidence。

## Acceptance matrix

| AC ID | Verification method | Expected result | Evidence |
| --- | --- | --- | --- |
| OHS-AC-1 typed closure | generator/schema/Swift/provider parity + malformed Catalog negatives | operation、step、action、effect/binding exact；unknown/mismatch build-time fail closed | contract tests + generator zero drift |
| OHS-AC-2 reversible preset | install/status/remove + path/hash/type/mode/permission drift matrix | no admin；absolute identity closed；status machine-readable；remove preserves source files | Swift contract tests + host status receipt |
| OHS-AC-3 secret boundary | TTY/Keychain/PTY positive and missing/locked/wrong/repeated/unknown-prompt negatives；secret scan | password never appears in argv/env/plist/receipt/WAL/log/receipt/Artifact；failure publishes nothing | contract tests + redacted host run |
| OHS-AC-4 input admission | corrupt ZIP, size/hash mismatch, expired lease, wrong target/binding | rejection before first process; dispatch count 0 | Runtime contract tests |
| OHS-AC-5 signing postflight | real SDK `sign-app` through typed Swift lane followed by pinned `verify-app` | non-empty signed HAP, cert/profile readback and hash report; filename/exit 0 alone never passes | real host run record |
| OHS-AC-6 lineage | source binding inheritance + matching/stale/wrong-target `debug.hap@1` consumption | only exact inherited target/binding/stable identity is consumable | Artifact/Runtime contract tests |
| OHS-AC-7 recovery | cancel, timeout, crash after write/before verify, restart, corrupt/partial output | no blind replay; complete verified output reconciles; otherwise unknown/failed and bounded cleanup | recovery tests |
| OHS-AC-8 headless device loop | LaunchAgent UDS submit typed sign, then typed `debug.hap@1` | install/package/process readback and Artifacts close on exact device; manual hapsigner/HDC=0 | real-device run or honest blocker |

## Negative and recovery tests

- Java/JAR/keystore/cert/profile missing, symlinked, non-regular, permission-widened or hash-drifted。
- Keychain item absent/locked, wrong password, hapsigner prompt missing/repeated/unknown, PTY timeout。
- output path pre-exists, partial output, verify-app nonzero/empty cert chain/empty profile, receipt truncation。
- source lease expired/tampered/device-bound to another target；output binding cannot be invented or dropped。
- daemon restart at before-spawn、after-sign、before-verify、after-verify/before-publish boundaries；zero
  unknown-effect replay。
- scan plist、receipt、Job JSON/WAL、stdout/stderr、Artifact payload 与 test failure text，拒绝 secret。

## Required gates

- `sh scripts/check-sdd.sh`
- `.venv-sdd/bin/python -m unittest discover -s scripts/catalog_gen -p "test_*.py"`
- `.venv-sdd/bin/python scripts/catalog_gen/generate.py --check`
- `swift test --package-path Packages/ArkDeckKit --parallel --num-workers 8`
- final commit 后的 `scripts/check_pr_paths.py --preflight`。

## Deviations

无隐式豁免。设备、USB 信任、Keychain 或本地签名材料不可用时，OHS-AC-8 记录环境缺口或
`BLOCKED_BY_PRODUCT_DEFECT`；host test/fake/plan-only 永不计入真实硬件通过。

## Result gate

- [ ] OHS-AC-1..7 passed
- [ ] OHS-AC-8 real-device passed，或给出可复查且不伪造的外部环境 blocker
- [ ] 四条本地门与 preflight passed
- [ ] secret scan passed，零敏感数据进入 evidence
- [ ] Task 状态与 verification 结论随同一个实现 PR 如实更新
