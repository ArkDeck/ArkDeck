# CHG-2026-006 Verification Plan

> Status:planned
> Change:CHG-2026-006-dayu200-m0b-bringup@r2
> Core baseline:CORE-2.0.0

本文件是 immutable verification plan;实际结果由 Task run/evidence 记录。全部
真机步骤由人类维护者执行;Agent 不执行真实 `hdc`。

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| HW-M0B-DAYU200-DISCOVERY-001 | human-operated USB discovery/toolchain capture | 稳定 device identity、hdc 三端版本、tool hash、实测设备 build 全部记录;逐命令 argv/exit code 自证只读白名单合规;evidence JSON 过 schema 校验(provider:none);至多支持 `observed` 行 | pending |
| HW-M0B-DAYU200-AUTH-001 | on-device authorization workflow observation | 双分支如实记录(r2):(A)设备有信任 UI——unauthorized→人工信任→ready 迁移被捕获,至少一条 denied/timeout 负路径观察或如实记录不可复现;(B)设备族无信任 UI(首例:EVD-M0B-DAYU200-20260718-001 的 DAYU200 build)——operator 明确记录新鲜枚举(重插)前后均无信任提示,`list targets` 字节可比对地呈现稳定 authorized 态,负路径记录为不可复现并给出原因;两分支均:零 server kill;key 材料不复制/不入仓库 | pending |
| HW-M0B-DAYU200-RAWCAPTURE-001 | per-stream byte-exact controlled capture | device-family raw output 分 stream 采集 + exit code + SHA-256;含序列号字节仅存维护者受控位置,仓库只记 hash;零改写、零 golden 登记 | pending |
| HW-M0B-DAYU200-UIDUMP-PROBE-001 | read-only hidumper probe capture | runbook 固定的只读 hidumper 查询全部采集;为后续 integration change 固定 HiDumper 包装提供输入;零兼容性声明 | pending |
| HW-M0B-DAYU200-SUPERVISOR-001 | ArkDeck production supervisor real-device observation(依赖 TASK-M1-006 done) | external ownership 判定正确;仪表化自动 lifecycle/subserver 计数恒 0;endpoint 隔离成立;设备出现/消失 fan-out 被观察;仅补充既有 observed 行 | pending |

> Revision r2(2026-07-18):`HW-M0B-DAYU200-AUTH-001` 由单分支
> (unauthorized→trust→ready)修订为上表双分支;r1 原文见 git 历史(main
> `f8817d9` 及之前)。已按 r1 记录的结论不因本修订追溯改变:
> `EVD-M0B-DAYU200-20260718-001` 的 AUTH-001 **FAIL(as written, r1)保持有效**;
> 如需按 r2 重新评定,须以独立 evidence 步骤经维护者 review 进行,不得把 r1
> 采集直接解释为 r2 通过(matrix status rules 同款约束)。

## Gate

- 本 change 只产生 `observed`(或最多 `partial`)hardware matrix 行;`verified`、
  兼容性与支持声明不在本 change 范围,不得由本 evidence 推出。
- 只读命令白名单(design.md)是硬边界:白名单外命令出现即该 AC fail,并须在
  run.md 记录偏差与设备状态复核结论。
- evidence 记录必须符合 `contracts/hardware-evidence.schema.json`(2.0.0)并经
  维护者 PR review 合入;matrix 行与 evidence 同 PR。
- `GAP-DAYU200-*` 四个 gap 不由本 change 解决;DEC-002 保持 open。
