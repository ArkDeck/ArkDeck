---
id: CHG-2026-006-dayu200-m0b-bringup
revision: 1
status: approved
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-2.0.0
platforms: [macos]
---

# M0B: first real-device bring-up evidence for DAYU200 (RK3568)

## Why

DEC-001 已 decided(#53,2026-07-18):首个目标设备为 DAYU200(RK3568),镜像输入
锚定 CHG-2026-003 pinned identity。`hardware-matrix.md` 仍为 `empty / pending M0B`,
`project.md` 的总体工期在 M0B 之前保持 `TBD / 待硬件确认`,`ui-dump` spec 的
HiDumper 调用包装也明确要求 M0B 真机验证后才能经 integration change 固定。本 change
产出首批 real-device evidence:真机 HDC 发现、授权工作流、工具链/设备 build 事实、
device-family raw output 受控采集,以及(M1-006 合入后)ArkDeck 生产 supervisor 的
真机观察。全部真机操作由人类维护者执行;evidence 只能产生 `observed`/`partial`
matrix 行,不构成任何支持声明。

## What changes

### In scope

- 人类操作的真机 bring-up runbook 与受控采集脚本(agent 起草,人类执行):
  1. USB transport 下的 `hdc list targets [-v]` 发现与稳定 device identity 记录;
  2. 授权工作流观察:unauthorized → 设备端人工信任确认 → ready;至少一条
     denied/timeout 负路径观察或如实记录不可复现原因;
  3. toolchain/设备事实:hdc client/server/daemon version、tool path/hash、实际
     观察到的设备 OpenHarmony build/API 信息(以设备为准,不从镜像文件名推断);
  4. device-family raw output(list targets、含设备的 checkserver 等)分 stream
     逐字节采集 + exit code + SHA-256,存放受控 evidence 位置;本 change 不把
     含真实序列号的字节登记为仓库 golden fixture(登记与脱敏政策属后续
     integration change);
  5. `hdc shell hidumper` 只读探测,采集 `ui-dump` spec 所需的调用包装事实;
- (依赖 TASK-M1-006 done)ArkDeck 生产 HDC supervisor 对真机的观察:external
  server ownership、自动 lifecycle 调用计数 0、endpoint 隔离与 fan-out 在真实
  设备在场时的行为;
- 按 `contracts/hardware-evidence.schema.json`(2.0.0)产出 evidence 记录,并以
  `observed` 状态更新 hardware-matrix 行(经维护者 PR review)。

### Out of scope

- 任何 flash/烧写、任何 Provider 实现(DEC-002 open;四个 GAP-DAYU200-* 未解);
- 任何写设备状态的操作:install/uninstall、file send/recv、reboot、tmode/tconn
  切换、kill/start server、修改设备设置(唯一例外:授权信任确认由人类在设备端
  完成,这是 bring-up 固有且设备端可撤销的动作);
- TCP transport 与 channel protection 真机观察(需 tmode 切换,推迟);
- 把 raw capture 登记为仓库 golden fixture、修改 integration profile/lock、
  HiDumper 包装的正式固定(全部属后续 integration change);
- `verified` hardware matrix 行、兼容性/支持声明、Core Requirement/AC/contract/
  baseline 修改、release claim;
- Agent 执行任何真实 `hdc`(M0A 结论:`hdc version` 隐式拉起 host server;真机
  命令一律人类按 runbook 执行)。

## Impacted specifications

- Core behavior:none · Core baseline update:no
- Platform Profile / Integration lock:unchanged(HiDumper 包装与 golden 登记由
  后续 integration change 依本 evidence 修改)
- hardware matrix:新增 `observed` 行(evidence 合入后)

## Platform impact and revalidation

| Declared platform | Disposition | Reason |
| --- | --- | --- |
| macOS | no revalidation trigger | host 侧无产品代码变更;真机 evidence 为新增 |
| Windows | out of scope; lifecycle unchanged | no implementation or support claim |
| Linux | out of scope; lifecycle unchanged | no implementation or support claim |

## Safety, evidence and compatibility

- 全部真机操作由人类维护者执行并记录 operator 与 physical target confirmation;
  只读命令白名单在 design.md 封闭,白名单外命令不得执行;
- `GAP-DAYU200-RECOVERY-PATH` 仍 unknown:M0B 禁止任何可能使设备不可启动或
  状态漂移的操作;设备固件如需准备,由维护者自行以厂商工具/文档完成,不进入
  ArkDeck evidence、不构成 ArkDeck 能力;
- evidence 记录符合 `hardware-evidence.schema.json`,raw capture 以 hash 固定并
  存受控位置;含设备序列号的字节不进仓库;
- simulation/fake/plan-only 不进入 hardware 行;本 change 只产生 `observed`/
  `partial`,不产生 `verified` 或支持声明。

## Approval

- Proposal 经 PR #54 合入 main(`f4cfc8f`,2026-07-18,status:proposed)。
- 正式批准:2026-07-18 由本 approval-only PR(先例 #14/#40/#45)将本 change 置为
  `approved`;批准由维护者 review/merge 本 PR 构成(V2 git-native 治理)。本批准
  不产生任务执行或任何真机 evidence:TASK-M0B-001 的执行另需物理 DAYU200 在场与
  维护者时间窗,TASK-M0B-002 保持 blocked(待 TASK-M1-006 done + M0B-001 done +
  独立 readiness PR)。
