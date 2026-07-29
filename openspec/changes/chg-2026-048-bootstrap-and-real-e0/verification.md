# CHG-2026-048 Verification Plan

> Change:CHG-2026-048-bootstrap-and-real-e0@r2
> Status:planned
> Core baseline:CORE-2.1.0 (canonical Core AC not claimed)

## Environment

- contract/fake 面:protected-main checkout,macOS arm64,零安装态 HDC
  依赖(fixture/fake 驱动);
- realHardware 面:维护者设备窗口(DAYU200 + 本机安装态 HDC),按
  Agent 起草的窗口步骤亲手执行并贴回 transcript;evidence 分类
  realHardware,序列号/connect key 字节脱敏后入仓。

## Acceptance matrix

| AC ID | Verification method | Expected result | Minimum evidence |
| --- | --- | --- | --- |
| `BER-BOOT-001` | bootstrap 状态机契约 + 结构负向 | 干净环境(零 fixture、零 binding)可走到候选观察;多候选须显式选择;unauthorized/offline → waitingForHuman 且提示明确;信任完成后自动续行;re-adopt 幂等;**bootstrap 内任何 mutation action 构造不可能**(类型面)且 admission 拒绝 mutation 请求 | contract |
| `BER-E0-001` | E0 action pack 契约 + 边界矩阵 | 全部 E0 action 经 typed request 可调;duration/buffer/filter/bytes 有界有默认;remote temp 由 provider 生成且含 session/step 绑定;截断/超时/invalid UTF-8/空输出显式 outcome;artifact 接收验 hash 并登记远端清理;未知 profile → unsupported | contract |
| `BER-SKEL-001` | fake-integration 端到端(真子进程)+ restart | client → daemon → engine → provider → **真实 descriptor 绑定进程** → 语义 verify → durable journal;重启后 job/timeline 可查;descriptor hash 漂移与 hostManaged 计划均被拒;请求含 changeId/taskId 被拒。**artifact 文件发布面递延 T14**(统一 artifact 模型),本 AC 不主张四文件落盘 | contract |
| `BER-HW-001` | 维护者窗口:真 DAYU200 + production HDC 端到端 | 一次 `arkdeck device adopt` + `observe.device@1` 提交在真设备上得到 succeeded 与完整 job timeline(artifact 文件面随 T14);除设备侧首次信任外零人工命令 | realHardware(窗口后补记) |
| `BER-HW-002` | 维护者窗口:重启/拔插恢复 | daemon 中途重启后恢复或安全重做只读观察;拔插后凭 rebind 证据重新识别 binding;不一致 fail-closed | realHardware(窗口后补记) |

## `BER-BOOT-001`

- 状态机八态逐迁移契约(每态进入/退出条件、非法迁移拒绝);
- effect ceiling:bootstrap 的 action 类型是观察族封闭枚举的子集,
  mutation 构造点在类型面不存在(编译保证)+ admission 负向测试;
- 多候选:两候选 fixture → 返回候选列表并要求显式选择;单候选自动;
- waitForPhysicalTrust:unauthorized fixture → waitingForHuman +
  人类可读提示;信任翻转后(fixture 状态切换)自动 resume;
- durable target:adopt 产生 targetID + stable identity sha + binding
  revision 1;重复 adopt 同一设备 → 同 targetID,零重复创建;
- daemon 重启后 waitingForHuman 状态可恢复。

## `BER-E0-001`

- 每 action 一组契约:合法参数往返、越界拒绝(duration>上限、bytes>
  预算、filter 超数、property 不在 allowlist);
- remote temp 命名:含 session/job/step 成分,两次调用零冲突;
  cleanup action 只接受 provider 自己生成的路径(任意路径拒绝);
- parser 矩阵:每 action 的截断/invalid UTF-8/空输出/未知 profile 四格;
- artifact 接收:hash 不符拒绝并保留远端(不静默清理);hash 相符登记
  清理;清理失败记 cleanup debt。

## `BER-SKEL-001`

- fixture 工具驱动全链:adopt(bootstrap)→ submit(v2,零治理字段)
  → engine → provider lower → dispatcher(**真实 spawn**,identity-bound
  路径,fixture 工具字节)→ 语义 verify → durable journal;
- daemon stop → 新进程 recover → job/result/timeline 可查;
- 治理字段(changeId 等)在 daemon 边界即被拒;
- descriptor 字节漂移(fixture 工具替换)→ dispatch 拒绝。

## `BER-HW-001` / `BER-HW-002`(realHardware,窗口后补记)

- 窗口步骤由 Agent 起草(host 侧自测一切可测项后交付),维护者亲手
  执行并贴回 transcript;Agent 核验后以 evidence-only 追加补记;
- 序列号/connect key 以摘要脱敏形式入仓;raw 产物留 daemon 私有目录;
- 任一步失败如实记 blocked-attempt,不降级、不以 simulation 顶替。
