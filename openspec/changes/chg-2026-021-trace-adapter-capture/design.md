# CHG-2026-021 Design:hitrace/bytrace adapter 采集 MVP

> Status:candidate(随 proposal r1;approve 前不构成实现授权)
> Core baseline:CORE-2.1.0(零 Core 变更;认领 trace REQ-TRACE-* 的 macOS 面)

## 0. 采集命令面草案(候选;exact argv 由 TR-001 真机 provenance 固定)

probe(只读):hitrace/bytrace 二进制存在性 → help 输出(family 识别)→ tag 列表
(`-l` 类)。capture(deviceMutation,最小样本):带 duration/buffer/tag 的一次
采集,输出到 Job UUID 隔离路径 `/data/local/tmp/arkdeck/<jobUUID>/`(integration
profile 既定推荐)。**本节全部 argv 是登记候选,不是实现依据**——TR-001 登记前
adapter 不得实现;登记后 exact argv/成败 marker/输出族以 registry 为准(先例:
CHG-015 readonly-probes、CHG-008 M0B-后固定 wrapper;M0A/M0B 教训:help 可能
exit 0 回错误行、成功无固定 marker,一律以登记的真实形态为准)。

## 1. REQ → 既有 seam 映射(全部已在 CORE-2.1.0 契约就位,零新增 kind)

| REQ | seam |
| --- | --- |
| 001 adapter 选择 | probeHostTool/probeDevice + TR-001 registry(help family → capability matrix;未知 family fail-closed,AC-001) |
| 002 capability 受限配置 | catalog `trace-presets`@1.0.0(runtime_rule:unsupported diff、显式接受或 fail preflight;buffer 单位 adapter-must-confirm) |
| 003/004 参数快照/回写/恢复 | snapshotParameter/setParameter(readbackPolicy=required)/restoreParameter + catalog `attachment-debug-profile`@1.0.0(missing 不得以 false/0 伪造) |
| 005 reboot/binding | rebootDevice + waitForDisconnect/Reconnect + Core device-binding(歧义 → awaitingRebindConfirmation) |
| 006 隔离接收 | captureRemoteFile(catalogId=trace-presets,ownedRemotePath=Job UUID 隔离)+ receiveFile(host partial → 验证 → 原子发布,M1-005 storage 契约)+ cleanupOwnedRemotePath(仅验证成功后) |
| 007 immutable raw/过滤 | verifyArtifact/hashFile + postprocessArtifact(derived + 删除统计;"删前两行"仅 parser 证实 chatter,AC-007 golden) |
| 008 honest progress | 阶段化进度(config…restore),仅可靠总量显百分比(REQ-FLASH-011 同族语义) |
| 009 artifact completeness | manifest 记录 tool/tag/duration/buffer/before-after-restored/hash/过滤统计;空 trace exit 0 不判 succeeded(exit0≠成功准则) |

## 2. Adapter 选择(REQ-TRACE-001)

help 输出族识别 → 与 TR-001 registry 的已登记 family 精确匹配 → 选 hitrace/bytrace
adapter;不可解析/未登记 family → 该工具 unknown,不可选、不猜测、raw help 可查
(AC-001);并存时按 registry capability matrix 决策,不按工具名/系统版本推断。
与 M1-006 registry 采用同构:fail-closed、hash-pinned、未登记即 unsupported。

## 3. 参数安全(REQ-TRACE-003/004;含契约缺口收紧)

已知契约缺口(2026-07-14 评审在案):Core `setParameter` schema 未绑定 catalog。
本 change 在 **trace workflow 层**收紧:参数 mutation 只接受
`attachment-debug-profile` catalog 内登记的参数名,catalog 外一律拒绝(fail
closed);不改 Core schema(零 Core 变更边界)。set 后 readback 逐项比对,不一致
→ 不进入 capture、dispatch 0、mismatch 审计(AC-004);missing 参数临时恢复禁用、
持久变更须显式确认(AC-003)。

## 4. TASK-TR-001 provenance 登记形态(先例 CHG-2026-015/005)

versioned registry(trace-probes/1.0.0:每命令 exact argv、intent、authority、
timeout、成败判定 marker、输出族样本引用)+ golden fixtures(help family、tag
list、最小 raw ftrace 头样本;`.gitattributes` binary 先行)+ 逐文件 SHA-256 hash
closure + redacted manifests(序列号/用户路径不入仓)+ OPENHARMONY-TOOLS profile
与 lock bump。采集走 runbook + 人工执行(scripts/ud_capture 或 m0b harness 复用
评估归 TR-001 readiness);登记认可 = evidence PR 维护者 review/merge。

## 5. 分期与边界

- TR-002(host contract)与 TR-001(device provenance)无实现依赖可并行;
  TR-003 硬依赖 TR-001 done。三任务各自 readiness/实现/done PR。
- trace capability = release optional、requires:[];本 change 不动 required 集。
- hardware-matrix:本 change 不新增行(9 AC 无 realHardware 面);未来真机 trace
  capability 行须独立 evidence(REQ-TRACE 无此要求,不预设)。
- Windows/Linux:not started 保持;平台不得改变 typed step/effect 语义(AGENTS 边界)。
