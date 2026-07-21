# TASK-PD-001 r2 fresh rerun attempt — BLOCKED

## Run identity

- Execution base:`b01cab60a405704ee59f9f2b11e6eba102b4fa9f`
  (`main`,包含 r2 implementation
  `0076e44dcaed45605c1cccefc093a82b246a4ef5`)
- Attempt time:2026-07-19 00:18–00:33 +0800,Asia/Shanghai
- Environment:macOS 26.5.2(25F84),arm64;Xcode 26.6;CPython 3.14.6;
  SDD lint 使用 CPython 3.11.15
- Evidence class:platform blocked-attempt record;不是三项 AC 的 fresh passing
  evidence,不是硬件/设备 evidence
- Final status:**BLOCKED**。远程 host 锁屏使 broker 的 NSOpenPanel/PowerBox
  无法取得人工文件选择。collector 在 create-only publication 前取消,未创建
  fresh output directory,未生成或覆盖任何 acceptance evidence。

## Source identity

| File | SHA-256 |
| --- | --- |
| `scripts/partition_decode/decode.py` | `3c2dc859bf32fa693250f02d8a10e77d6febbbb287d0aadd093e2839435307f9` |
| `scripts/partition_decode/evidence.py` | `e0775499cd7ccbdeb978795c7973a3594b856a043de9e873836c41e27fb291c4` |
| `scripts/partition_decode/macos_input_broker/collect_platform_evidence.py` | `ae5ab75c7d9efb583983ca894b0e1c6deebc038c7563d4cb01058c3bebdce056` |

## Commands and results

| Command/action | Result |
| --- | --- |
| `env PYTHONWARNINGS=error /opt/homebrew/bin/python3.14 scripts/partition_decode/test_decode.py` | PASS:35 tests,OK |
| 在普通 sandbox 内运行 fresh collector | exit 1:`verified broker run failed`;未发布 output |
| 在受控 sandbox 外运行同一 fresh collector | fresh broker 进程启动并等待 NSOpenPanel/PowerBox;Computer Use 明确报告 Mac locked,无法完成选择 |
| 取消等待中的 collector | exit 130;随后只读进程审计确认无 collector/broker 遗留进程 |
| 检查目标 fresh output directory | 不存在;create-only publication 未发生 |
| `env PYTHONWARNINGS=error /opt/homebrew/bin/python3.14 scripts/archive_characterization/test_scan.py` | PASS:36 tests,OK |
| `env ARKDECK_PYTHON=/opt/homebrew/bin/python3.14 scripts/check-sdd.sh` | 环境失败:该解释器无 PyYAML;不记为产品/SDD failure |
| `env ARKDECK_PYTHON=/opt/homebrew/bin/python3.11 scripts/check-sdd.sh` | PASS:0 errors,0 warnings,111 acceptance IDs |
| `git diff --check` + 新文件 trailing-whitespace/locator/secret 扫描 | PASS |

collector attempt 没有取得 archive descriptor,没有设备操作、网络、HDC/vendor
tool、mutation 或磁盘解包。随后在 PR diff 检查阶段,Agent 错误调用
`git diff --no-index /dev/null <new-run-record>` 展示未跟踪文件；该命令可能
stat/open 真实 `/dev/null`,违反本任务零设备 gate,虽不属于 broker/acceptance run,
仍在此显式披露且不得记作任何 passing evidence。未把静态/单元测试结果记作 fresh
platform acceptance evidence。

## Independent completion blocker in merged r2 implementation

合入版 `evidence.py` 的 canonical summary 固定报告
`TEST-DECODE-DAYU200-PARTITION-001` 为 `FAILED / BLOCKED`,原因是 zlib 强制保留
opaque DEFLATE sliding history,而批准的 r2 AC 字面要求非目标 body 不得跨 chunk
retention。`test_decode.py` 同时要求 process audit 保持
`partitionAcceptanceSatisfied:false`。因此即使 host 解锁,当前实现生成的 fresh run
也不能支持三项 AC 整体 PASS 或任务 `done`;Agent 不得自行把 codec state 解释为
AC 豁免。

## Acceptance conclusions

| Test ID | Conclusion |
| --- | --- |
| `TEST-DECODE-DAYU200-PARTITION-001` | **BLOCKED / NOT EXECUTED**:无 fresh pinned-archive output;合入版另显式保留 DEFLATE retention blocker |
| `TEST-DECODE-DAYU200-INPUT-BOUNDARY-001` | **BLOCKED / NOT EXECUTED**:单元/静态测试通过,但签名 artifact/runtime receipt/platform evidence 未发布；PR 检查另误用 `/dev/null`,整体零设备 gate 不成立 |
| `TEST-DECODE-DAYU200-RECONCILE-001` | **BLOCKED / NOT EXECUTED**:无 fresh pinned-archive mapping/reconciliation,不得复用 r1 evidence |

TASK-PD-001 保持 `blocked`,change 不得标记 `verified`。解除条件为:

1. 维护者通过治理变更明确 r2 AC 对强制 codec sliding history 的边界,或提供满足
   当前 literal AC 的 approved remediation;
2. macOS host 处于可交互解锁状态,由签名 broker/PowerBox 完成 fresh collector;
3. 三项 Test ID 均有同一次 fresh run 的可复查 platform evidence,再以独立
   completion/status PR 起草 `blocked→done`。
