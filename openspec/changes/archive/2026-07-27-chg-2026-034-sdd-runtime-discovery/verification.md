# CHG-2026-034 Verification Plan

> Change:CHG-2026-034-sdd-runtime-discovery@r1
> Status:passed # 2026-07-27；三 AC 结论与全链 merge OID 见 proposal.md「Verification closure」段；仅在维护者 review/merge 本 verification-closure PR 后生效
> Core baseline:CORE-2.1.0（零 Core delta）

## Environment

- macOS primary checkout + Codex linked worktree，CPython 3.14.6 / PyYAML 6.0.3；
- temporary Git primary/linked worktrees whose paths include spaces；
- fake Python/pip/venv argv targets for negative/bootstrap contracts，零下载；
- GitHub Actions Linux existing SDD guard remains an unchanged regression surface。

## Acceptance matrix

| AC ID | Verification method | Expected result | Evidence |
| --- | --- | --- | --- |
| `SDR-DISCOVERY-001` | stdlib host contract + current linked-worktree integration | resolver 精确遵守 explicit → local → shared → PATH；plain linked-worktree checker 只读复用同 repository primary venv；普通 checkout/Git 不可用回退封闭；路径不拆词 | `TASK-SDR-001` run |
| `SDR-DIAGNOSTIC-001` | adversarial process/fixture matrix | 缺 executable/module、错 version、坏 pin 与坏高优先级候选稳定非零；不 traceback、不静默 fallback；checker 的 pip/venv/network/write canary 为 0 | `TASK-SDR-001` run |
| `SDR-BOOTSTRAP-001` | fake bootstrap argv contract + manual pre-existing-env preflight | bootstrap 只在直接调用时写 primary `.venv-sdd` 并安装当前 requirements；不调用 global pip/`--break-system-packages`；结果须经 exact import/version preflight | `TASK-SDR-001` run |

## Negative and recovery tests

- explicit interpreter 不可执行、能启动但无 yaml、yaml version 漂移；
- current-worktree venv 存在但损坏，同时 shared/PATH 健康：必须拒绝而非静默降级；
- shared venv 缺失、Git common-dir 查询失败、common-dir 相对/绝对路径；
- checkout、common-dir 和 Python 路径含空格；
- requirements 文件缺失，或 PyYAML pin 缺失、重复、非 exact；comment 与无关的未来
  dependency 行不得造成误报；
- fake `pip`、`venv` 与 network canary：checker 调用数严格为 0；
- bootstrap base Python 失败、venv create 失败、pip install 失败、post-install import
  失败：均不报告成功，后续 checker继续 fail closed；
- linked-worktree shared-discovery removal canary 必须红，恢复实现后转绿；
- rollback 单次 revert 后回到原 resolver，机器本地 ignored venv 不进入 diff。

## Evidence classification

- resolver/bootstrap tests：`hostOnlyContract`；
- 当前 linked-worktree plain checker：`hostOnlyIntegration`；
- existing CI regression：`ci`；
- product/device/hardware/destructive evidence：`not run`。

## Deviations

任何自动安装/联网、global Python 修改、profile 写入、跨 repository venv 发现、
`check_sdd.py` 规则变化、dependency pin/workflow 修改或无法稳定二值化的路径均不是
隐式 deviation；任务保持 blocked 并先修订 change。

## Result gate

- [ ] 三条 change-local AC 全部有正例、具名负例和可复查 run evidence
- [ ] linked-worktree red canary 与恢复后 green 均在案
- [ ] checker invocation 的 install/network/write count 为 0
- [ ] SDD checker 结果与变更前 canonical baseline 一致
- [ ] task implementation、done 与 change verification 各自经独立 PR
