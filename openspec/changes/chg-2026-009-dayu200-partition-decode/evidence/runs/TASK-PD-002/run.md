# TASK-PD-002 fresh platform run record — 2026-07-20(r5 之后)

- Evidence class:`platform`(fresh signed-broker run;governed 输出经 collector
  in-process create-only publisher 发布)
- Change:`CHG-2026-009-dayu200-partition-decode@r5`(`approved`)
- Operator:维护者 lvye(fuhanfeng)本人——console 解锁、NSOpenPanel 选择均亲手
  执行;Agent 零 collector/broker 启动,仅 preflight 脚本起草与事后核验/本记录
  起草(M0B #58 先例)
- Run time:2026-07-20 16:58 CST;execution base = `main`(readiness amendment
  PR #162 合入后,含 TASK-PD-001 r5 done `946ebfd`)
- Fresh outputs:`platform-2026-07-20-r5/`(六文件,由 collector 单次 run 发布;
  逐文件 SHA-256 见 `summary.md` 表并经本记录独立复算确认)
- Prior blocked attempt:`platform-attempt-2026-07-20.md`(15:35,r5 修复前;
  保持 immutable)

## Preflight(操作者执行,全部通过)

- 12 个 pinned source hash(readiness amendment 重钉值:4 decoder + 7 broker +
  r5 新测试文件)复算逐一相符,零漂移;
- pinned archive identity:size `732948803`、SHA-256 `fc7637f3…5280` 逐字相符;
- console 解锁(`CGSSessionScreenIsLocked` 键缺席,collector 启动前与结束后各一次);
- `python3 -V` = `Python 3.14.6`。

## Run facts

- collector exit `0`;NSOpenPanel 由维护者本人选择 pinned archive;fresh broker
  artifact 由未修改 source 新建(ad-hoc 签名,如实记录于 platform evidence,
  不构成 release signing claim);create-only publication 成功,六个 governed
  输出落盘。
- **r5 修复的端到端证明**:runtime receipt 的全部 `sandbox_check` 派生字段现为
  真 JSON 布尔(`true`),collector 逐项校验全部通过——2026-07-20 15:35 blocked
  attempt 的根因(NSNumber int 装箱)已被 TASK-PD-001 r5 修复并经本 run 实证。

## Agent 独立核验(2026-07-20,零 collector/broker 重启)

- 六文件 SHA-256 独立复算,与 `summary.md` 登记表逐一相符;
- `broker-runtime-receipt.json` 重算 hash 与 `broker-platform-evidence.json`
  绑定值一致;三个 core 输出与 receipt `coreOutputSha256` 逐一 hash-bound;
- receipt 布尔语义检查:`policyChecks` 全部值为 JSON 布尔类型(含四个 device
  路径的 readDenied/writeDenied 与 network-outbound/process-exec);
- 敏感扫描:六文件对用户路径/操作者名/archive locator/key 标记零命中;
  platform evidence 的 environment 仅含 OS/arch/Xcode/Swift/Python 版本字段;
- `scripts/check-sdd.sh` 0 errors/0 warnings/111 acceptance IDs;
  `git diff --check` clean(本 evidence PR 分支)。

## Acceptance conclusions(承 `summary.md`,同一次 fresh run)

| Test ID | Conclusion |
| --- | --- |
| `TEST-DECODE-DAYU200-PARTITION-001` | **PASS**(r3 codec receipt + bounded stream-discard 对 pinned archive 验证) |
| `TEST-DECODE-DAYU200-INPUT-BOUNDARY-001` | **PASS**(fresh signed broker/platform/runtime 绑定验证) |
| `TEST-DECODE-DAYU200-RECONCILE-001` | **PASS**(inventory 全成员与全分区 exact-name 对账) |

## Boundary

non-authoritative,仅对 pinned archive identity 成立;`parameter.txt` 原文与
archive locator 未入仓;不推导、不声称任何烧写地址、协议、compatibility、
executable profile 或 hardware support(该类结论归 DEC-002/FA-001 及后续
change);`ready→done` 仍须独立状态 PR 经维护者 review/merge。
