# Tasks — CHG-2026-052 SDD acceptance-count currency

> 本 change 是 host-only/offline guard-test remediation。proposal 的 `approved`
> 与本任务 `ready` 仅在维护者 review/merge proposal PR 后生效。

## TASK-GCC-001 — Derive the real-baseline expected count from accepted conformance

- Status:ready # proposal/ready candidate；仅在维护者 review/merge 后生效
- Platform:all
- Requirements/AC:`GUARD-COUNT-CURRENCY-001`
- Depends on:none
- Readiness input pins:

  ```yaml pins
  - path: scripts/test_check_sdd.py
    blob: 2b7b046d4253050d932ad971605a61aeccb5f469
  - path: scripts/check_sdd.py
    blob: 43d889cd4c97f958270157514f79059c316f0b3e
  - path: openspec/verification/core-conformance.yaml
    blob: 0684bdb4efaac9659cf137d18d83cacc22ce6816
  - path: .github/workflows/sdd-guard.yml
    blob: 1ab1db896b4ee83207e006b2720cdbe1c0d27e70
  ```

  Audit base:`dd3b110daed9311f9c2c732c7c971c21482bed59`。任一 pin 漂移时停止，
  重新确认 reader contract 与 CI 调用面；不得猜测兼容。
- Applicable failure patterns:none（单文件离线 test reader；主要风险由
  invalid-shape matrix、固定 Allowed paths 与真实 subprocess test 直接覆盖）
- Production reachability:not applicable（只运行 Python contract test；不进入
  product composition、Runtime job 或 effect dispatch）
- Trusted fact sources:`acceptance_index.count` 由 accepted
  `openspec/verification/core-conformance.yaml` 提供；`check_sdd.py` subprocess
  提供实际 errors/warnings/count 摘要。实现 PR 不允许修改这两个 producer，caller
  只能读取并比较，不能同时构造事实与证明。
- Allowed paths:
  - `scripts/test_check_sdd.py`
  - `openspec/changes/chg-2026-052-sdd-acceptance-count-currency/evidence/**`
  - 本 `tasks.md`（仅本任务状态与 evidence 引用）
- Forbidden paths:
  - `scripts/check_sdd.py`
  - `scripts/check-sdd.sh`
  - `scripts/check_pr_paths.py`
  - `scripts/automation_config.json`
  - `.github/**`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/baselines/**`
  - `openspec/verification/core-conformance.yaml`
  - `openspec/verification/acceptance-index.txt`
  - `openspec/verification/acceptance-cases.yaml`
  - `Packages/**`
  - `ArkDeckApp/**`
- Risk:low（唯一行为是 test expected-value sourcing；错误会使 CI false green/red）
- Hardware required:no

### Deliverables

- 一个封闭 reader：只接受 `acceptance_index.count` 的正整数（显式拒绝 bool）。
- 合成 valid/invalid shape contract test。
- 真实仓库 subprocess test 使用 reader 产生精确摘要，并继续要求 exit 0、
  0 errors、0 warnings。
- `evidence/runs/TASK-GCC-001/run.md` 记录 base/pins、命令、结果、AC 结论、
  偏差与零 device/network dispatch。

### Verification

- `GUARD-COUNT-CURRENCY-001`：
  - current main manifest = 111 时，完整 `scripts/test_check_sdd.py` PASS；
  - synthetic count = 114 时 reader 返回 114；
  - missing/bool/string/zero/negative 均 fail closed；
  - 实现合入后，CHG-2026-051 archive candidate 报告 114 时同一 suite PASS，
    无需再次修改 `scripts/test_check_sdd.py`。
- `scripts/test_check_sdd.py`、`scripts/test_check_pr_paths.py`、
  `scripts/check-sdd.sh`、`git diff --check` 全 PASS。

### Notes / handoff

- implementation、tests、run evidence 与 `ready → done` 同一 PR。
- change 级 verified 与 archive 仍使用各自独立 PR。
- 在本 proposal/ready PR 合入前不得修改 `scripts/test_check_sdd.py`。
