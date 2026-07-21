# CHG-2026-009 Verification Plan

> Status:passed;maintainer confirmation 见 proposal.md Verification closure(2026-07-20)
> Change:CHG-2026-009-dayu200-partition-decode@r5
> Core baseline:CORE-2.0.0

本文件是 immutable verification plan;实际结果由 Task run/evidence 记录。
decoder 零 path open/device read,workflow 零设备/网络/subprocess;identity gate
不命中即整体拒绝。trusted-fd/sandbox broker evidence 缺失即整体 fail。
r4 新增的 headless contract case 只验证 implementation 与 receipt validator；它不
替代下列三项 platform case,也不要求或允许读取 pinned archive。

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| DECODE-DAYU200-HEADLESS-001 | branch-complete unit/fault/static tests | process audit schema 精确表达 r3 codec 配置与 runtime lifecycle；成功、DecodeFailure、其他异常与 cancellation 均以显式 finally 关闭 codec/remainder；receipt 缺失、矛盾、cap 越界或 cleanup 未完成时 acceptance false；无 preset dictionary/clone/export/history view、无额外 plaintext buffer、无 allocator forensic-zeroization 声明；完整 regression 与零 production subprocess/network/device-mutation 静态审计通过；不运行 collector、不读取 pinned archive、不生成三项 platform evidence | passed（2026-07-19：TASK-PD-001 r4-headless run；实现 PR #124 `110071c1`、done 状态 PR #125） |
| DECODE-DAYU200-RECEIPT-CONTRACT-001 | synthetic receipt vector matrix + collector per-term validation + main.m boolean-boxing source pin | collector 逐项校验并以字段名+实际值报错;布尔字段必须为真 JSON 布尔,整数 0/1 替代被拒且报出字段;canonical true 向量全项通过,int-boxed/缺失/篡改向量各有具名错误;main.m 全部 sandbox_check 派生字段经显式 BOOL 装箱的 source-literal 断言钉定;零 broker/GUI/archive/device/network dispatch;不满足也不降级三项 platform AC | passed(TASK-PD-001 r5 done,PR #160/#161;`evidence/runs/TASK-PD-001/r5-broker-receipt/run.md`,14/0) |
| DECODE-DAYU200-PARTITION-001 | identity-gated streaming decode + branch-complete tests | pinned identity 强制;允许以 ≤1 MiB plaintext chunk 消费目标前 member body,应用须在请求下一 chunk 前释放全部上一 chunk 引用,且不得解析/hash/返回/记录/持久化/复制非目标明文;只允许 gzip-DEFLATE base window bits 15(zlib `wbits=31`)、最大 32768-byte history 的 codec-owned opaque state 与 ≤65536-byte compressed remainder 跨调用存在,应用不得取得/clone/export/persist 该 history,目标或失败后立即销毁;raw identity/gzip pass、header/body count+bytes 与 codec lifecycle 精确审计;封闭文法未知形态显式 fail;evidence 含映射表/S2 引用/hash 引用,无原文无 locator,仅对 pinned 镜像成立 | passed(TASK-PD-002 done,PR #164;`evidence/runs/TASK-PD-002/platform-2026-07-20-r5/`) |
| DECODE-DAYU200-INPUT-BOUNDARY-001 | static call-target audit + descriptor negative tests + macOS sandbox evidence review | production decoder 只接收预打开只读 fd,零 path open;首次 read 前 fstat 普通文件,非普通 fd 零 read fail;launcher 是独立签名/验证的 sandbox broker,封闭 entitlement/policy 排除所有 character/block device-node namespace(含 USB/serial/raw disk)并以 descriptor 传递;现有含 device entitlement 的 App 不自动合格;缺任一 broker/policy/signing evidence 即 fail | passed(TASK-PD-002 done,PR #164;fresh signed broker/platform/runtime 绑定,ad-hoc 签名如实记录) |
| DECODE-DAYU200-RECONCILE-001 | mapping ↔ 17 成员清单对账 | 每成员归位或显式孤儿;每无成员分区显式列出;non-authoritative,不推导烧写地址,零烧写/兼容/支持声明 | passed(TASK-PD-002 done,PR #164;17 成员/全分区对账) |

> Revision r2(2026-07-18):上表替换 r1 的 literal no-other-member-read 与
> path-open 静态零设备证明。r1 run/evidence 不追溯重判；必须由 r2 implementation
> + fresh run 重新验证全部三项 AC。

> Revision r3(2026-07-19):第一行将 application-visible non-target plaintext
> retention 与 RFC 1951/zlib 必需的 opaque 32 KiB history 分离,并封闭配置、
> 可见性、compressed remainder 与销毁 evidence。r1/r2 run/evidence 均不追溯
> 重判；r3 合入后仍须独立 readiness 与同一次 fresh 三项 platform run。

> Revision r4(2026-07-19):新增 `DECODE-DAYU200-HEADLESS-001` 作为不替代既有
> platform AC 的 implementation contract gate,并把执行拆为 TASK-PD-001 headless
> remediation 与 TASK-PD-002 interactive platform evidence。原三项 expected result、
> minimum evidence 与同一次 fresh run 规则不变；r1/r2 evidence 仍不可复用或重判。

> Status update(2026-07-20,随账本对齐 PR 合入):`DECODE-DAYU200-HEADLESS-001` 已由
> `evidence/runs/TASK-PD-001/r4-headless/run.md`(implementation PR #124
> `110071c1003ecc06eb4106d2e8ea5b554029329a`、done 状态 PR #125)二值 PASS,上表该行
> Status 据此同步。其余三项 platform AC 保持 pending,归 TASK-PD-002 所有。本更新只
> 同步账本,不构成新的验证结论,也不改变 change 级 `Status:planned`。

> Revision r5(2026-07-20):TASK-PD-002 首次 fresh platform run 被 collector
> fail-closed 拒绝(blocked-attempt record
> `evidence/runs/TASK-PD-002/platform-attempt-2026-07-20.md`),根因=`main.m` 以
> `@(expr != 0)` 装箱 sandbox_check 结果产生 NSNumber(int),receipt 序列化为 JSON
> `1` 而非 `true`,collector 对 network-outbound/process-exec 的 `is True` 身份检查
> 恒 FAIL(四个 device 路径 dict 相等因 Python `1 == True` 意外通过)。r5 新增
> `DECODE-DAYU200-RECEIPT-CONTRACT-001` contract gate,TASK-PD-001 重开为 r5
> broker-receipt remediation(r4 headless done 不重判),TASK-PD-002 fail-closed 回退
> `blocked`(r5 done + readiness amendment 重钉 broker pins 后恢复)。三项 platform
> AC 的 expected result、minimum evidence 与同一次 fresh run 规则不变。

> Status update(2026-07-20,随 TASK-PD-002 `ready→done` 独立状态 PR 合入):三项
> platform AC 依 TASK-PD-002 merged `done`(evidence PR #164,同一次 fresh run)翻转
> `passed`;`DECODE-DAYU200-RECEIPT-CONTRACT-001` 依 TASK-PD-001 r5 done(#160/#161)
> 补同步 `passed`(#161 为单文件翻转未及本表,系账本补记)。本更新只同步账本,不构成
> 新的验证结论,也不改变 change 级 `Status:planned`;change 级 verify/archive 另行
> 独立 PR(先例 #48/#49)。

## Task ownership

| Task | Acceptance ownership | Completion meaning |
| --- | --- | --- |
| TASK-PD-001 | `DECODE-DAYU200-HEADLESS-001`(r4,closed)+ `DECODE-DAYU200-RECEIPT-CONTRACT-001`(r5) | r4 headless contract 已闭且不重判;r5 完成=broker receipt 布尔语义与 collector 逐项校验可复查;原三项 platform AC 仍 pending |
| TASK-PD-002 | 原三项 `DECODE-DAYU200-*` platform AC | 已合入的 TASK-PD-001 完整 commit 经未修改签名 broker 在解锁 console 上由同一次 fresh run 验证 |

## Gate

- 只读硬边界:任何 subprocess/网络/设备访问或磁盘解包出现即整体 fail；sandbox
  deny 不得通过主动打开真实 device node 取证,设备类负测使用 synthetic/mock fd
  metadata + entitlement/policy/signing inspection。
- capability gate:仅 caller 声明“fd 可信”不构成 evidence；decoder 静态出现
  `open/openat/lstat` path target、broker 含 device entitlement、policy 未封闭或
  descriptor 传递链不明确,任一即 fail。
- stream gate:非目标 body 只允许为推进目标前单流而消费；读取目标后成员、
  任意应用层解析/hash/log/persist/return/copy、上一 plaintext chunk 引用跨下一
  chunk 存活或计数漂移均 fail。
- codec-state gate:只允许 gzip-DEFLATE base window bits 15(zlib `wbits=31`)、
  无 preset dictionary/codec clone/history view 的单一 codec；history 最大 32768
  bytes、application-held compressed remainder 最大 65536 bytes,目标/失败/取消后
  销毁。缺配置或 lifecycle
  receipt、应用可取得 history/body view、额外解压明文 buffer、state export/persist
  任一即 fail。该 gate 不声称 allocator residue forensic zeroization。
- headless gate:TASK-PD-001 只允许 synthetic/fixture fd、unit/static/fault tests 与本地
  临时目录；启动 collector、读取 pinned archive、写 mapping/reconciliation/platform
  summary、复用 r1/r2 output 或声称任一原 Test ID PASS 均 fail。
- platform binding gate:TASK-PD-002 必须记录 TASK-PD-001 已合入的完整 commit OID、
  decoder/validator blob hash 与签名 broker artifact/runtime binding；branch 名、dirty
  worktree、source/hash 漂移或任何平台 run 内 source 修补均 fail。锁屏、取消、picker
  失败或任一 AC 无法二值化时 create-only publication 不得留下 governed partial output。
- 解码失败是合法结果:未知文法如实记录,不得猜测凑表。
- 本 evidence 是 DEC-002 输入的候选,登记须另行 governance PR(先例 #52);
  gap 状态不由本 change 改变。
