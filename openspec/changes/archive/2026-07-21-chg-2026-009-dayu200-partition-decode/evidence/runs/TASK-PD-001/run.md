# TASK-PD-001 run — blocked partition-decode evidence

## Run identity and final status

- Publication/revalidation base:`c3134f05d97591c6cd875dfe12ee2854b5151a0d`
  (`origin/main`,2026-07-18 rebase 无冲突；初始执行基线
  `795918481cab0f619558847527bd5a2af8d6bd70`)
- Date/timezone:2026-07-18,Asia/Shanghai
- Environment:macOS 26.5.2(25F84),arm64;CPython 3.14.6;stdlib only
- **Final status:BLOCKED / `TEST-DECODE-DAYU200-PARTITION-001` failed.**
  `parameter.txt` 是单一 gzip/DEFLATE tar stream 的第 8 个成员；定位其 header
  实测读取并丢弃前 7 个成员内容，共 178168731 bytes。Accepted AC 明确要求
  “without reading other member contents”。同时 path-based `lstat→open` 存在替换
  为字符/块设备后先 open、再由 fstat 拒绝的竞态，不能静态证明 absolute zero
  device access。故当前 candidate 不满足 AC，不能标记 task done 或 change
  verified。
- 若产品意图是允许“流式解压/丢弃但不解析、不保留、不落盘”，或接受可信 fd/
  OS sandbox/threat model 作为零设备边界，必须由独立 governance PR 澄清/修订
  AC 并经维护者批准；本实现与本 evidence 不自行改写这些边界。

## Input references and safety boundary

- Archive:732948803 bytes,SHA-256
  `fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280`；
  locator/basename/host directory 不记录。
- `parameter.txt`:788 bytes,SHA-256
  `35464e3f0b883a8a043dd45ae7ab2342c86b7aa27f24aa1e5a0ccfb6f442d048`；
  原文不入仓库。
- Archived inventory:
  `openspec/changes/archive/2026-07-18-chg-2026-003-dayu200-image-characterization/evidence/member-inventory.json`,
  17 rows,SHA-256
  `429763e6fabcaaa2f7323eab862fdb8c65d63ecc88afb441a36073ee5c35818c`。
- 最终 remediation 使用 `lstat` 在任何 open 前拒绝已知 device/FIFO/directory/
  symlink；随后以 `O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC` open，并用 fstat 复核竞态
  替换及两次读取 pass 的稳定性。特殊文件负测 mock `os.open`，未故意打开真实
  设备节点；但上述 path replacement race 仍使静态零设备证明不成立。

## Superseded invalid attempts(disclosed,not acceptance evidence)

- 早期 review 版本的特殊文件测试实际打开了 `/dev/null`，whitespace 检查也以
  `/dev/null` 为 baseline。它们违反 verification gate 的零设备访问边界；此前
  run.md 中“零设备/PASS”结论无效，现已撤回而非静默覆盖。
- 早期实现把非目标 member span 描述为“未返回 parser/未保留”，但没有如实判定
  其仍属于“读取其他成员内容”。当前 process audit 显式记录 body count/bytes，
  summary 与 CLI 均报告 blocked。

## Clean remediation rerun commands and results

| Command | Result |
| --- | --- |
| `git fetch origin main`；`git rebase --autostash origin/main` | 更新至 `c3134f05d97591c6cd875dfe12ee2854b5151a0d`，autostash 恢复成功，无冲突 |
| `env PYTHONWARNINGS=error python3 scripts/partition_decode/test_decode.py` | 36 tests,OK；special-device paths 使用 mock，且测试显式保留 open-before-fstat 竞态为 blocker；raw wrapper 覆盖 read/readinto 与双遍合计 |
| `python3 scripts/partition_decode/decode.py --archive <external locator> --out-dir <temporary evidence dir>` | evidence 写出后 exit 3；stderr 明确 `decode blocked` |
| 将上述 4 个临时 output 与 governed evidence 逐文件 `cmp` | bytes 全部相同 |
| `env PYTHONWARNINGS=error python3 scripts/archive_characterization/test_scan.py` | 36 regression tests,OK |
| `env ARKDECK_PYTHON=/opt/homebrew/bin/python3.11 scripts/check-sdd.sh` | 0 errors,0 warnings,111 acceptance IDs |
| 显式 stage 本 task 的 allowed-path 文件后运行 `git diff --cached --check` | exit 0；检查覆盖 tracked 修改与全部 9 个新增文件，未使用 `/dev/null` |

## Evidence outputs(failure evidence)

| File | SHA-256 |
| --- | --- |
| `partition-mapping.json` | `965e3bf3bd926c76a646a1bc02ce1f3f4ba855b4e09a7e61b48872195c131347` |
| `member-reconciliation.json` | `55c3515667ff6b1bd8cc922721b0c46a649eee9203a6f8a40c23397765b2d4ad` |
| `process-audit.json` | `c1a84bfddb51267186f3e88a2f60766f9a0899daa6b0704ca663049f285c0db1` |
| `summary.md` | `0458924836c01590ed1460c44943bcc0c7ae9693dbc53ab8228a6b2aa86adc8f` |

`process-audit.json` 的 closed validator 与完整 expected document 精确相等比较，
因此拒绝额外 key、locator、虚假 `counterProvenance` 或任一确定性读取指标漂移。
它如实记录:

- identity pass raw 732948803 bytes、gzip pass raw 17956874 bytes、合计
  `rawBytesRead:750905677`；两遍均由统一 wrapper 对底层 `read/readinto` 返回值计数
- `nonParameterMemberContentsRead:7`
- `nonParameterMemberContentBytesReadAndDiscarded:178168731`
- `partitionAcceptanceSatisfied:false`
- bounded chunk 1048576、8 headers、7 discarded spans、4 次 regular-file gate
  checks；零 subprocess/network/device-mutation dispatch，但
  `zeroDeviceAccessStaticProofSatisfied:false` 且保留 1 条潜在 path-open 路径。

## Acceptance conclusions

| Test ID | Evidence class | Conclusion |
| --- | --- | --- |
| `TEST-DECODE-DAYU200-PARTITION-001` | platform | **FAILED / BLOCKED**:pinned identity、parameter hash、closed grammar、零落盘、无 locator/raw 与静态零 subprocess/network 均有证据；但单流定位读取了 7 个其他 member body，且 path open 竞态不能静态证明零设备访问，均不满足 accepted AC。早期 `/dev/null` 访问也使此前 PASS run 无效 |
| `TEST-DECODE-DAYU200-RECONCILE-001` | platform | passed in isolation:17 inventory rows 全量列出；11 个 `.img` 中 9 个 exact-stem mapped，`chip_prod.img`/`sys_prod.img` explicit orphan；6 个 partition orphan；不做 alias/address/support 推断 |

Task 整体不得 `done`。`tasks.md` 的 `ready→blocked` 是本次起草状态，只有维护者将
对应 status/governance PR review/merge 后才生效；若后续修订 AC，须重新进入
readiness 与 verification，不得复用本 run 作为 passing evidence。
