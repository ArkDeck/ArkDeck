# TASK-RF-001 Run — 阶段 A:契约/Profile 定义(host-only)+ 真机正向烧写(设备窗口)

- Change:CHG-2026-020-dayu200-real-flash / Task:TASK-RF-001
- Base revision:readiness PR #227 合入后 main。
- Agent 零设备命令:契约/Profile 定义(host-only documentReview)+ 正向 crib 起草 + 事后
  核验 + evidence 起草;真机正向烧写由人类维护者亲手执行(REQ-FLASH-015,恢复演练先例)。

## Part 1 — 契约/Profile 定义(host-only,本 PR 完成)

- 交付:`images-tar-contract.md` — `images.tar.gz` 输入契约(17 成员逐一 SHA-256)+
  `RockchipFlashProfile`(允许分区 9 mapped、写序、地址、prerequisites)+ 禁写面 +
  命令面。锚定 CHG-2026-003 `member-inventory.json`、PD-002 `partition-mapping.json`
  (`965e3bf3…`)、FA-001 §2 地址表,只读引用零改写。
- **RF-CONTRACT-001**(documentReview)= **PASS**:逐项对照见 `images-tar-contract.md` §5
  (允许分区/orphan 禁写/逐成员 hash/写序地址锚定/prerequisites/命令面与 design §1/§2
  逐项一致)。`./scripts/check-sdd.sh` 0/0/111、`git diff --check` 干净。

## Part 2 — 真机正向烧写(SUCCESS,2026-07-21 设备窗口)

- 状态:**done**。详见 `forward-flash-2026-07-21.md`(SUCCESS):九个 PD-002 mapped 分区经
  Loader 态 `wlx` 正向全部写入成功、`rd` 复位后重启进系统、postcheck 58B
  `USB Connected localhost`;**RF-REALFLASH-001 PASS**。首验用 pinned 包(CHG-003
  `fc7637f3…5280`,17 成员 hash MATCH),命令面与恢复演练 attempt #5 逐字同构。
  hardware-matrix.md 新增 observed 行 `EVD-RF001-DAYU200-20260721-001`(完整 supported
  行待 RF-002 Provider AC)。脱敏 transcript `transcript-forward-2026-07-21.txt`。
  Agent installed-HDC/device/destructive dispatch `0/0/0`。

### (历史)执行形态说明

- 人类维护者按 `images-tar-contract.md` §4 命令面(=
  正向 crib,恢复演练 `rehearse-r4.sh` 的正向产品化:身份门/进态/mode-gate/ppt 前置/
  逐分区 wlx/rd/postflight + `images.tar.gz` 解包与逐成员 hash 校验)在 DAYU200 真机
  正向烧写 pinned `images.tar.gz`(CHG-003 17 成员,`fc7637f3…5280`)。
- 待记录(REQ-FLASH-003/014/015):逐命令 argv/输出/判定、成员 hash 校验、destructive
  确认(`userdata` 强确认)、postflight `Connected`、`hardware-evidence.json`(schema
  2.0.0,provider none)、脱敏 transcript、operator/窗口/恢复路径;Agent destructive
  dispatch 0。**RF-REALFLASH-001**(realHardware)于此后判定;`hardware-matrix.md`
  supported 行须真机验收背书(REQ-FLASH-014)。中止如实记录为 blocked-attempt(恢复
  演练先例)。
- 风险:destructive 写设备可能变砖,但恢复路径已 CHG-2026-016 验证可行(即使失败可用
  同一 Loader `wlx` 路线恢复)。

## 边界

Part 1 documentReview 不构成真机结论。RF-001 `done` 须 Part 1 + Part 2 均可判定后另用
独立状态 PR;不构成 DAYU200 以外设备、hardware support、兼容性或 release 声明;
simulated 永不进 hardware matrix。
