# <TASK-ID> run record — YYYY-MM-DD

> V2 轻量格式:每次 task run 一份,存放于所属 change 的 `evidence/runs/<TASK-ID>/run.md`。
> 只记录 redacted 摘要、hash、命令与结果、受控位置引用;禁止私钥、真实设备原始 dump/trace、大二进制与敏感日志。
> realHardware 证据另需满足 `contracts/hardware-evidence.schema.json` 与 `governance/enforcement.md` 的硬件条款。

- Evidence class: `platform` | `simulation` | `fake` | `plan` | `realHardware`
- Core baseline: `CORE-x.y.z`
- Scope: 本次 run 覆盖的 Requirement/AC ID
- Base: 本 run 绑定的完整 40-hex protected `main` OID(不用截断前缀)
- Input pins: 关键输入的完整 hash/pin(工具、fixture、载体、readiness pins 复核结论)
- Producer → consumer: 本 run 实际走通的路径两端;未端到端跑通时写明缺口
- Evidence currency: `current` | `superseded` | `invalidated`
  - `current`:本 run 精确绑定当前被评审 bytes;
  - `superseded`:保留历史事实,不得用于当前结论;
  - `invalidated`:执行/输入/环境不满足方法,不构成 acceptance evidence。

  状态变化后须在**事实原位**逐处标注(陈旧 hash 行、PASS 行、计数行),
  不得只在文件尾部写一句模糊 supersession 注记。

## Environment

- OS、toolchain、外部工具的确切版本(与 verification 环境要求对应)

## Work completed

- 实际完成的工作,与 task deliverables 逐项对应

## Commands and results

| Command | Result |
| --- | --- |
| — | — |

## AC conclusion

对 Scope 内每个 AC 给出唯一结论:passed / failed / pending(附原因与缺口)。
不得声称超出 evidence class 的支持(如 simulation/fake 永不计入 realHardware);
任务状态本身经维护者 PR review 更新,run record 不改任务状态。

## Deviations and residual risk

- 偏差、未执行项与后续动作;destructive dispatch 计数(应恒为 0,除非该 run 由人类亲手执行或持有效 standing authorization)。
