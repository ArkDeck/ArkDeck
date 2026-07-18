# TASK-M1-005 run — Session/Artifact storage, manifest, and host-volume coordination

## Run identity and classification

- Base revision:`0297951f40abf4c99276fa71775654e438d46fd2`
  (`governance: restore TASK-M1-005 readiness (#36)`)
- Working branch:`agent/task-m1-005`
- Date/timezone:2026-07-17,Asia/Shanghai
- Environment:macOS 26.5.2(25F84),arm64;Xcode 26.6(17F113);Apple Swift 6.3.3
- Host volume observation:`/dev/disk3s5`,4 KiB block size,76,291,560 KiB available at run
  start.Production identity values are intentionally not copied into evidence;the contract run proves
  same-volume equality and synthetic different-identity rejection.
- Execution authority/classification:`standardAgent`;local contract + macOS platform filesystem
  evidence only
- Hardware/network/HDC/device access:none
- Destructive/device dispatch:none.Retention deletion was exercised only against dedicated temporary
  Session directories created by the test;the run is not realHardware,platform conformance,or a release
  claim.

## Locked and readiness inputs

以下 SHA-256 在实现前固定;本任务没有修改 Core、locked contracts、baseline、integration 或
platform profile。

| Input | SHA-256 |
| --- | --- |
| `openspec/baselines/CORE-2.0.0.yaml` | `07227da529608f26dcbbc8843f1623278b51cb3036cd93e1e9ed4af6f8880aa6` |
| `openspec/specs/session-artifact-storage/spec.md` | `954598be54c3b390f6811990ed6dadc19b7598e6628a210b06f36480aa1731cf` |
| `openspec/architecture/platform-ports.md` | `47752d0cc767867762ef1bc2f65d4aafbd20e81a5622e43320509ffac27a9962` |
| `openspec/contracts/manifest.schema.json` | `52be768697e75fc98a00a386345162af2e1a8ca3607b86f755adb766cf0ad489` |
| `openspec/contracts/workflow-step.schema.json` | `624d61071070ec1f873a811307fe7eb39f7697c37a68ed3ef8fad774522d1688` |
| `openspec/platforms/macos/profile.md` | `54bd9b295799cb8d93bf397eeb585f24828463f4f1fce1e59a0693f65369d0bf` |
| change `proposal.md` | `fd44eb9eb90da950eecd2db3ab79a191c8c9f3ca38222db0d57cdcf045bee099` |
| change `design.md` | `432c53cfdc4b1c2def598e5f72c289838b8541809aebaa282a643e22dc038948` |
| pre-run change `tasks.md` | `336f6cad57a3efdd5de0e270b13216d1133420c0c824f9e945ce08e471be5e6e` |
| change `verification.md` | `c9346c913ef1f91d950f9f9f0dd36097c6b1674cdc1965d5fd638000c0dc5186` |
| change `scope.yaml` | `ad60766a364a8e0682802924b080e1a7ea06b0f1d2e2a62231f2f267386fa7b5` |
| change `acceptance-cases.yaml` | `fabb191e4d3d4e3e249ea2960a5178bf085f0a023709ee9912c821dea6a05a44` |
| M1-003 `DurableFiles.swift` | `596bb37003f750b8637927082e99415718153fca357c576b357bef3cc6bfbbc0` |
| M1-003 `JournalEventValidation.swift` | `9f3cca998e12bf49fa3af72322ae955681fa4f41a9b71a346ea23b8af78c6cf6` |
| M1-003 `JournalReplay.swift` | `22fb0309feeb44eb171788578858ad300f94312014e12714e6148e45618f848e` |
| M1-003 `RecoveryCoordination.swift` | `9fdce53e49e064bf37e0a016c4062872bb716a3baaf847b831e66cd8bd254b37` |

## Work completed

- 实现按 UTC 年/月分区的 per-Job Session layout,包含 journal、snapshot、command/event/session
  audit、raw/derived/partial 与 manifest 路径;Session root 排他创建并持久化 session/job identity,
  创建和打开时拒绝同名采纳、身份错配、不安全目录、受控路径 symlink 穿越和 catalog escape;
  audit/artifacts/raw/derived/partial 全部目录 entry 均有 durability barrier。Session 创建 API 必须
  显式接收 coordinator 签发的 live metadata claim,在任何年/月/Session 目录或 identity 写入前验证
  Job 与 sessions root 的真实 volume identity,并以 provisional/committed/failed 两阶段状态绑定唯一
  Session ID + standardized root。只有 `mkdir(Session root)` 成功后才记录 Session mutation;非原子
  ENOENT preflight 后在 root mkdir 竞争中得到 EEXIST 的 loser 保持 unbound、permit 立即失活,下一次
  coordinator accounting/admission 会 purge 该 claim,不要求为 winner 的 Session 伪造 terminal receipt。
  root 创建后在任何子目录/identity mutation 前捕获 owner-safe root 的 device+inode;此后的 identity
  file-sync、目录创建或任一 directory-sync failure 进入只允许原 claim + exact Session ID/root/inode 的
  显式 repair 状态。retry 会拒绝 root identity 变化,幂等补齐缺失目录、同 identity 的空/截断文件和全部
  durability barrier;若 descriptor acquisition 失败则保存可证明的 root inode 供 retry,否则只在 empty
  root 可安全删除时回到无 mutation 状态,从不把未证明 root 授予 Artifact/terminal capability。
  仅 repair/创建与全部 barrier 完成且再次验证 Session root volume 后 binding 才 committed;
  missing、wrong-Job、wrong-volume 或 finalization-only claim 均在创建前 fail closed。
- 实现 64 KiB 分块的 Artifact hash/write,`.part` 非空/format-prefix/optional-checksum 校验,
  `RENAME_EXCL` 原子发布和跨目录 rename 的 source/target directory sync;publication 强制使用
  coordinator 签发的 live claim capability,运行期 stop/finalization-only 会在每个 chunk 和 rename 前
  拒绝可选写入;每个实际写入 chunk 在共享 claim permit 下原子扣减 remaining-growth,同一 claim 的
  多 Artifact 写入和 coordinator update 观察同一余额,不能用 1-byte claim 扩张任意输出。claim 的
  volume UUID 在 layout root、已打开的 destination/final descriptor 及最终发布目录上分别绑定并在
  rename 前后复核,不能拿卷 A claim 写卷 B。发布前持久化隐藏 recovery record;rename 已成功但任一
  directory sync 失败时,相同请求会校验 source/final bytes、补做 file/source/target barrier 并返回同一
  ArtifactRecord,不会遗留无法进入 manifest 的 orphan final。recovery marker 之前的 deterministic
  `.part` 会按 source descriptor 指纹收养完整残留,或删除不完整残留、同步 partial directory 并退还
  实际占用 growth 后重写;marker 自身以临时文件 full-sync + `RENAME_EXCL` + directory sync 发布。
  write/file-sync/validation/marker write/sync/rename/directory-sync 任一失败后,同请求均可重试且总共只
  扣一份 Artifact bytes;低层 partial write 只保留实际落盘 bytes 的 claim charge。Artifact publication
  成功后 recovery marker 继续持有唯一 ArtifactRecord,包括 mismatched source retry 也不会删除;只有
  publisher 在 write-once manifest I/O 前已枚举并逐项验证 marker 与 proposed ArtifactRecord 精确一致,
  terminal manifest 完成自身 root-directory durability barrier 后才按预检 inode snapshot unlink marker 并
  同步 partial directory。unlink 后的 injected sync failure 已有 durable manifest 接管记录,identical
  manifest republish 会补齐 partial-directory barrier。
  recovery marker producer 与两个 consumer 共用 65,536-byte canonical bound:恰好边界可发布和恢复,
  超过 1 byte 会在 marker I/O 与 Artifact final rename 前失败,不会产生不可读 marker/final。
  publication transaction 由 16-way deterministic hidden lock shard +
  blocking `flock` 跨 store instance 串行,lock 文件数量按 Session 有界;打开 `.part` 后持续持有同一
  descriptor 完成 fingerprint、rename 与 barrier,rename 前后分别核对 path 与 descriptor 的 dev/inode、
  owner、link count 和安全 mode。fresh、无 marker 复用与有 marker recovery 三条路径均不在 hash 后
  重新按 pathname 打开,因此竞争实例或 pathname substitution 不能替换待发布 bytes。raw 无论新写还是
  复用 residual 均重新 `fchmod` 为 owner-read-only 后再 full-sync。sync ENOSPC 统一映射到 Storage errno 域。
  source 以 nonblocking + `fstat(S_IFREG)`
  拒绝 FIFO/字符设备;每次流式 copy/fingerprint 前后对同一 descriptor 的 dev/inode/generation、size、
  mtime/ctime 与实际读取 byte count 做稳定性比较,即使没有 expected checksum,读取期间 append、truncate
  或原地改写也不会被当成稳定快照发布;raw 在发布前持久化为只读且 store 无覆盖 API。derived publication
  禁止 caller-supplied arbitrary origin,必须使用 bounded canonical `DerivedArtifactProvenance` typed request,
  同时传入 ordered source `ArtifactRecord`;request 绑定 source ID/hash、非空 rebuild parameters/statistics,
  publication 从 anchored Session root 打开并保留每个 source descriptor 到 final rename 后,验证真实 bytes 与
  source record 一致。terminal Manifest 再解析 typed provenance,逐项比较 `derivedFrom` source SHA-256,
  拒绝 unknown source、hash mismatch 与直接/间接 lineage cycle。1 GiB 输入镜像只流式 hash/引用,不复制。
  输入引用的 size/hash/volume 全部
  来自同一个 descriptor,同时持久化 device/inode/generation 并在 hash 后校验 pathname 仍指向同一文件。
  Artifact writer 在入口、取得 shared shard lock 后、marker 与 final rename 临界区均要求 claim 已
  committed 绑定到 exact layout Session ID + standardized root,同 Job/同卷的 foreign 或 unbound claim
  在目标目录发生任何 mutation 前拒绝。shard lock 内同时检查 terminal manifest 不存在,因此等待中的
  writer 不能在 write-once manifest 提交后继续发布 orphan final/marker。Session root、`artifacts`、
  raw/derived/partial 全部以 owner-safe、same-device `O_DIRECTORY|O_NOFOLLOW` descriptor 逐层锚定;
  partial/marker/lock/final 的 create、open、unlink、`RENAME_EXCL` 和 fsync 都使用
  `openat`/`unlinkat`/`renameatx_np` 相对这些 descriptor 执行。transaction 返回前再次比较每层
  directory path 与持有 descriptor 的 dev/inode;在 `.artifactReplace` 注入点把中间 `artifacts`
  替换为外部 symlink 会 fail closed,外部目录和原锚定 raw final 均不产生发布文件。
- 实现 bounded canonical `SessionAuditRecord` 和 production
  `DurableSessionAuditAppending`:preview/confirmation/intent/outcome append+full-sync,严格 JSONL,
  descriptor-lifetime nonblocking `flock` 强制单写者,torn tail 重开时截断到最后完整 durable record,
  相同 record ID/bytes 重试会再次执行 file/directory sync barrier、冲突 duplicate 不 poison writer;
  关闭重开后以 64 KiB 固定缓冲按 correlation 从 durable bytes streaming replay;实际 write/sync 后的不确定
  fault 显式抛错并 poison 当前 writer。writer 同时持有 Session root、`audit` directory 与
  `session.jsonl` descriptor,每次 append、idempotent barrier repair、replay 与 volume query 前后都以
  `fstatat(AT_SYMLINK_NOFOLLOW)` 比较三层 parent/entry 的 owner/device/inode；移动整个 `audit/` 后在原
  entry 放置指回旧目录的 symlink 也不会让 orphan inode fsync 返回 durable success。producer/consumer
  共用 72 KiB 完整 canonical record bound,timestamp 另限 64 UTF-8 bytes；整个 JSONL 另有 16 MiB/
  65,536-record 上限,scan 在分配前先检查 `st_size`,长期内存只保留 bounded record-ID fingerprint 而非
  materialize 全日志,因此 append 不会生成 reopen 必然拒绝的 record,replay 内存也不随历史日志无界增长。
- 实现 production `SessionManifestPublishing`:对 locked `manifest-1.0.0` 顶层/嵌套 shape、
  workflow-step、status/mode/authority 条件和 recovery shape 做 strict validation;解码后 effect/
  cancellation/binding policy 必须与持久声明完全一致,拒绝 typed policy 静默升级、非法 baseline、
  planned unknown 和 standardAgent destructive-success。canonical document 构造与 publish 均在任何
  write-once I/O 前执行 16 MiB canonical-byte bound,因此 publisher 不会写出自己随后无法 load 的
  manifest;发布拒绝 terminal manifest 改写;load 以 `O_NOFOLLOW` + regular-file/16 MiB bound 拒绝
  symlink/无限输入;跨实例 lock file + `flock` 串行发布,
  同目录临时文件 full-sync、`RENAME_EXCL` write-once、directory sync;identical republish 会补做目录
  durability barrier,conflict 不 poison publisher。任何新 manifest 临时文件/rename 之前先枚举所有现存
  publication marker,以 descriptor/path identity 和 bounded canonical decode 验证其 record 在 proposed
  manifest 中逐字段精确存在;冲突 fail-fast 且 manifest path 保持不存在。提交后 cleanup 只消费预检的
  inode snapshot、执行幂等 unlink 与 partial-directory barrier。publisher 在 manifest cross-instance lock
  内按固定顺序持有全部 16 个 Artifact publication shard locks,覆盖 marker preflight、manifest
  write/full-sync/`RENAME_EXCL`、root sync 与 marker cleanup;Artifact writer 释放单 shard 后 manifest 才能
  形成 quiescent write-once snapshot,而已排队 writer 在恢复后观察 terminal path 并 fail closed。
  `serverLifecycle` confirmation 与 related Step IDs round-trip,manifest 不铸造 authority。
  Recovery unexecuted compensation 同样比较 raw/typed policy,
  abandonment confirmation 与 manifest 统一接受合法 fractional ISO-8601 timestamp。locked validator
  在逐项 shape 后执行 whole-graph validation:Step/Artifact/confirmation/compensation ID 唯一、binding
  revision 严格递增、Step revision 必须存在、confirmation/`derivedFrom`/compensation source 引用必须
  resolve、execution/record/recovery compensation 必须与 source Step 声明逐字段一致,且 `restored`
  参数的 before/restore UTF-8 bytes 必须相等；每个非 null `Step.arguments.confirmationId` 还必须解析到
  relatedStepIds 包含该 Step 的唯一 confirmation。journal create/repair/append 与 manifest publisher
  共同参与 Session `.manifest.lock` 的跨实例 `flock` 提交边界；writer 在锁内从同一 descriptor 重放最新
  durable state,terminal path 出现后拒绝新增/修复 journal。publisher 在该锁内 full-sync 并 replay
  owner-safe、same-volume、descriptor-bound journal snapshot,核对
  Session/Job/executionMode/executionAuthority/core baseline、Step 完整 typed declaration、按 revision 的
  confirmed binding identity、compensation intent/outcome 与全部 `journalEventIds` correlation,并要求 confirmed
  manifest 不含任何 outstanding intent 或 durable `outcomeUnknown`。TASK-M1-005 不定义 M1-003 之外的
  per-outcome reconcile proof schema;generic confirmed reconcile 即使带 positive binding、safe-boundary 和
  非空 evidence 也不清除、升级或改写既有 unknown/hazard,不能把未知 destructive outcome 转成 confirmed
  Manifest。任何非空 journal 还必须先到达 terminal state,
  以匹配 Manifest hash/status/certainty 的 `finalized` 作为最后一条 durable event；nonterminal 或 terminal
  但未 finalized 的 journal 都在 manifest path 出现前拒绝。每个 Step/compensation 的最后 durable
  outcome 还必须与 Manifest 的 disposition/result/outcomeCertainty tuple 一致；执行视图按 intent sequence
  选择最新 attempt,未完成的新 intent 优先于旧 outcome，且 Manifest 中每条 executed/outcomeUnknown
  Step/compensation 都必须有 durable attempt backing。confirmed succeeded 映射
  为 executed/confirmed/succeeded，confirmed failed/cancelled/timedOut 映射为
  executed/confirmed/failed，未解决 unknown 只能映射为 outcomeUnknown/outcomeUnknown/unknown。snapshot
  descriptor 从 preflight 持有到
  `RENAME_EXCL`,紧邻 rename 再比较 path/inode/generation/size/mtime/ctime；并发 writer 必须等到 commit
  后观察 terminal path 并 fail closed。manifest publisher 在任何 write-once I/O 前从 Session
  root descriptor 逐组件 `openat(O_NOFOLLOW)` 每个 declared Artifact,拒绝 ghost、symlink、unsafe
  owner/mode/cross-device path,并校验 regular file、nlink、size、SHA-256 与稳定 descriptor metadata;
  snapshots 从 preflight 持有到 commit,在最后 fault injection 后紧邻 descriptor-relative manifest
  `RENAME_EXCL` 再次验证。中间 `artifacts` namespace 替换因此在 manifest path 出现前被拒绝。
- 将 timestamp validation 收紧为 locked RFC 3339 词法、Gregorian 日历日期与 offset 范围校验;
  `2026-02-30`、`+24:00`、`+0800` 在 manifest/audit/recovery 三条路径一致拒绝,合法 leap-day、
  fractional seconds 与有冒号 offset 保持可用。
- 实现 macOS descriptor-bound volume UUID(`st_dev` fail-closed fallback)identity resolver、capacity/read-only probe 和
  actor-isolated `HostStorageCoordinator`:同卷最多一个 heavy writer,unknown writer 串行,有界 light
  writer按额度并行,metadata/finalization headroom 优先,soft claim overflow拒绝,remaining-growth
  直接赋值且只允许递减,运行期复检/ENOSPC/不同 identity fail closed。ENOSPC/finalization-only 为
  粘滞状态,清零 Artifact growth 但保留 terminal headroom 与 heavy claim;不同 identity 检查优先于
  finalization-only。无 UUID 时以 unsigned `st_dev` 只做初始同卷分组,运行期复检保守停止。
- 实现不可由调用方构造的 terminal persistence receipt:success/throw/cancel 只有在 outcome audit durable
  且匹配终态 manifest 原子发布后才 release;finalizer 在独立未取消 Task 中执行,operation 与
  finalization 双失败同时保留两个 error,任一 fault 或 receipt mismatch 均保留 claim/headroom。
  coordinator 在启动 finalizer 前原子关闭 optional-write permit;finalizer 要求 audit/manifest 共用同一
  Session root,并在 audit 前后和 manifest 发布后核对 claim volume,不能以卷 A claim 在卷 B 生成 receipt。
  每次 admission 生成不可复用 generation;terminal receipt 同时封装 generation、Session/root 与 volume,
  normal/recovered completion 都要求 receipt Session/root 等于 permit 在 Session 创建时的唯一绑定,
  防止同 Job/volume 的另一 Session 铸造 release 或复用相同 claimID 的新 permit 被旧 receipt 释放。
  completed receipt idempotency tombstone 使用默认 256-entry、可配置容量的 touch-on-hit LRU,避免长生命周期
  coordinator 随历史 Job 无界增长;超过窗口的旧 receipt 明确返回 claimUnavailable。每个 claim 同时保存
  pending terminal
  disposition;瞬时 finalizer/receipt 校验失败后,调用方可用保留的
  finalization-only claim 幂等重试 audit/manifest,再将 repaired receipt 交给 coordinator 的 recovery-
  completion API 或 claim-scoped `StorageClaimReleasing` adapter。只有 claim/job/disposition 完全匹配的
  receipt 才使 permit 失效并释放 accounting/headroom;重复 completion 返回 alreadyReleased,冲突或旧
  generation receipt 继续保留 claim,下一次 admission/accounting 会同步清理经 seam 完成的 inactive
  claim。
  实现 macOS filesystem `SessionDiagnosticExporter`:以 durable manifest 为唯一 Artifact 清单并要求调用方
  输入精确一致;导出必须持有同 Job、同 destination volume 的 live heavy claim,每个输出 chunk 原子消费
  shared remaining-growth,permit stop/finalization-only 立即拒绝,失败清理 sibling staging、同步 parent 并退还
  已删除 bytes 后同路径可重试。destination parent、sibling staging、全部中间目录与输出文件均由
  owner/same-device descriptor 锚定,使用 `mkdirat/openat/renameatx_np` 写入与发布；发布前后核对 staging
  entry inode,并从持有的 staging descriptor 重开每个输出路径、复核 regular-file identity/size/SHA-256。
  最终以 `RENAME_EXCL` 原子发布并再次核对卷身份；staging 或已发布 destination 被替换为 symlink 时
  fail closed 且不跟随删除/发布外部树。目标 `fstatat` 的非 `ENOENT` errno 原样返回。默认实际导出对所有 included Artifact role(含 `.plan`)做 bounded
  byte-level device-identifier redaction,支持 non-UTF-8;manifest 的 target/binding 以及 warnings、failure、
  parameters、recovery 等字段按完整结构路径统一 scrub,仅保护实际 enum/hash/timestamp 位置;受 schema
  约束的 `name`/`id`/`code`/Workflow argument identifier 生成 deterministic 合法 token,交叉引用使用同一
  映射,实际 SHA-256 typed arguments 保持 64-hex shape,其他 arguments 变化后重算 locked hash。
  Artifact ID、derivedFrom 与含标识的 relative-path component 同样生成合法 token并写入对应脱敏路径;
  Session/Job/recovery 交叉引用一致脱敏。raw/partial 默认排除且 export plan 只披露 opaque excluded token,
  仅显式 `.include` policy 保留标识;
  导出 manifest 更新脱敏 Artifact 的 hash、size 与 source-SHA lineage,同时保护 `kind/transport` 等 schema
  枚举。manifest substring replacement 使用不扩张 token,接近 4,096-byte 上限的密集 identifier
  parameter 仍可通过重验证;默认排除 raw 时,直接依赖被排除 source 的 derived 副本会显式重分类为
  diagnostic、清除 dangling `derivedFrom` 并写入 source role/hash export lineage；仍具完整 included source
  闭包的 derived 则保持 typed provenance,显式 include raw 时原 lineage 完整保留。identity/evidence 任意 JSON object key 也会 deterministic 脱敏,真实设备中
  仅作为 key 出现的标识同时进入 Artifact byte scrub pattern,synthetic 普通键不会污染 provenance。数字/自由
  文本 substring pattern 设 4-byte 下限且 Artifact 输出上限 64 MiB,避免短数字(如 slot `1`)导致膨胀。
  retention 的 pin-only unsafe margin 状态进入 coordinator
  admission 并阻断新 heavy/unknown writer;删除从经 inode 校验的 Sessions root descriptor 出发,逐组件
  `openat(O_NOFOLLOW)`、递归 `unlinkat` 且同步 parent,中间 pathname 被 symlink 替换也只删除已锚定目录;
  duplicate/pinned/unknown Session identity 显式抛错而非进程 trap。Artifact/manifest/audit/exporter 的
  durability failure 均归一到 `SessionStorageError` 域。

## Verification commands and results

| Command | Result |
| --- | --- |
| `swift format lint <TASK-M1-005 changed Swift files>` | passed on the final 2026-07-18 review closeout;0 diagnostics |
| `swift test --package-path Packages/ArkDeckKit --filter SessionArtifactStorageContractTests` | passed on the final 2026-07-18 closeout:58 tests,0 failures,0 skips(55 remediation methods with two previously unexecuted vectors corrected,plus 3 closeout vectors) |
| `swift test --package-path Packages/ArkDeckKit --filter JournalRecoveryContractTests` | passed on the final 2026-07-18 closeout:29 tests,0 failures,0 skips |
| `swift test --package-path Packages/ArkDeckKit` | passed on the final 2026-07-18 closeout:169 tests executed,0 failures,1 pre-existing opt-in manual sleep/wake skip;the 2026-07-17 cross-process RuntimePort environment failure did not reproduce |
| `scripts/check-sdd.sh` | passed on the final closeout;0 errors,0 warnings,111 acceptance IDs |
| `git diff --check` | passed on the final closeout |
| `rg -n '[ \t]+$|conflict-markers' <TASK-M1-005 untracked deliverables>` | passed on the current remediation;no trailing whitespace or conflict markers |

## Artifact, publication, and durability evidence

| Vector | Observed result |
| --- | --- |
| interrupted receive/finalization | injected Artifact file-sync returned actual `ENOSPC`;live claim became finalization-only;production terminal finalizer persisted the matching outcome audit and `storage.errno.28` failed manifest while journal and `.part` remained |
| raw → derived filtering | previous run:raw bytes/hash unchanged,published raw rejects write,and derived records source/hash/parameters/`removedLines=1`;current added typed-provenance vectors reject untyped/arbitrary origin,empty rebuild metadata,source-hash mismatch and post-publication source tamper before a derived final path appears;the added vectors type-check and await executable rerun |
| crash before Artifact rename | validated `.part` remains;final path absent;reconcile scan returns exactly one regular partial |
| runtime ENOSPC shard finalization | previously completed shard remains immutable;current shard retains a `65,536`-byte partial;failed manifest publishes both records and never reports success |
| claim-bound Artifact write | ENOSPC transitions claim to sticky finalization-only;revalidate after free-space recovery still stops and a second publish is rejected before writing |
| Artifact durability/error domain | partial creation,target rename and source partial-directory sync checkpoints all execute;file/source-directory sync ENOSPC is returned as `SessionStorageError.writeFailed(errno:ENOSPC)`;post-rename target-sync failure is recovered by a new store instance without consuming growth twice |
| Artifact pre-marker/recovery retry | partial-directory sync,write,file-sync,validation and recovery-marker write/file-sync/`RENAME_EXCL`/directory-sync faults each fail once and then publish successfully from the deterministic partial/final;corrected-checksum retry adopts the validated bytes;all eight fault cases consume exactly one Artifact size and retain one marker until terminal manifest commit |
| Artifact recovery-record ownership | post-rename target-sync failure leaves final+marker;mismatched-source retry returns `artifactAlreadyPublished` without deleting the marker,then the correct source returns the original record;terminal manifest durability takes ownership before marker unlink,an injected post-unlink partial-directory sync failure leaves the durable manifest readable,and identical republish repairs the barrier and returns success |
| Artifact recovery-marker bound | producer emits a canonical marker of exactly 65,536 bytes and both recovery/commit readers accept it;an otherwise valid 65,537-byte record is rejected before marker creation and final Artifact rename,leaving only retryable partial state |
| Artifact cross-instance publication | instance A pauses at its first write while holding the shared file lock;instance B reaches the same lock and cannot mutate the deterministic partial;A publishes bytes/hash exactly,then B fails its mismatched-source recovery without growth or final mutation |
| Artifact anchored namespace | publication holds Session root + artifacts/raw/derived/partial descriptors and performs lock/partial/marker/final operations relative to them;replacing `artifacts` with an external symlink at the final-rename fault point returns `invalidArtifact`,publishes no file in the external tree,and leaves no final in the displaced anchored raw directory |
| Artifact exact-Session capability | two same-Job/same-volume light claims create separate Sessions;Session B claim is rejected at Session A Artifact entry before raw/partial directory mutation,while Session A claim publishes normally |
| Artifact inode/mode binding | injected pre-rename move+replacement is rejected independently in fresh-write,unmarked reusable-partial and durable-marker recovery paths because fingerprint and rename retain one descriptor and the path inode no longer matches it;all final paths remain absent and displaced original bytes remain intact;a manually seeded complete `0600` raw partial is adopted only after unconditional chmod and publishes with all write bits cleared |
| Artifact source stability | without an expected checksum,deterministic append,truncate and same-size in-place overwrite at the post-stream validation boundary change descriptor size/mtime/ctime evidence and are rejected even when `st_gen` is unchanged;no final Artifact path is published |
| special-file source | FIFO open is nonblocking and rejected by `fstat`;`/dev/zero` input reference is rejected as non-regular without unbounded copy |
| simulated manifest/export | archived simulated manifest is published,materialized and reloaded;`executionMode=simulated`,synthetic provenance and fixture/scenario identities survive;changing only `executionMode` to execute is rejected by the production validator rather than accepted as hardware success |
| referenced input | logical size `1,073,741,824` bytes;allocated size `0` bytes;full 64-hex hash;device/inode recorded;Session copy count `0`;hash-time pathname replacement rejected |
| privacy export(platform) | previous run covers durable-manifest role integrity and path-aware redaction;current combination vector adds a published raw→derived Session whose default export excludes raw but keeps the derived bytes as a schema-valid diagnostic copy with explicit detached source-role/hash lineage,while explicit raw include preserves typed derived provenance;the 55-method source type-checks and executable rerun is pending |
| export admission/error | previous run covers claim/growth/error cleanup;current staging-substitution vector moves the already renamed export and places an external symlink at destination,the descriptor/file snapshot validation must reject success,unlink only the symlink and preserve the external sentinel;the added vector type-checks and awaits executable rerun |
| retention | expired ordinary Session deleted first;pinned Session preserved;unknown/pinned/escape/static-symlink targets rejected;after parent descriptors are opened,a tested month-directory→symlink substitution deletes only the moved anchored Session and preserves the external sentinel;pin-only over-margin plan has zero deletions and blocks heavy admission |
| durable audit | previous run:initial 4 categories/4 records/torn-tail/idempotent barrier behavior;current vectors add 72 KiB record + 64-byte timestamp bounds,a sparse 16 MiB+1 file rejected from `fstat` before allocation,and 300 records spanning multiple 64 KiB buffers whose replay materializes only one matching correlation;the additions type-check and await executable rerun |
| audit fault | previous run covers file-entry substitution and sync faults;current vector moves the entire held `audit/` directory and installs a symlink pointing back,expects the three-level descriptor ancestry check to reject append and reopen despite the final file inode still matching;the addition type-checks and awaits executable rerun |
| manifest publication | canonical size `2,153` bytes;SHA-256 `728c88386f1db245846bf1e691ae23af4dca45897582a8f49240508e287c9df9`;reopen exact |
| manifest write-once/durability | two publisher instances racing different terminal documents yield exactly one success;descriptor-relative `RENAME_EXCL` prevents overwrite;post-rename directory-sync failure is repaired by identical republish;conflict does not poison subsequent load;a schema-valid ArtifactRecord differing from its durable marker is rejected before any manifest path exists,then the exact record publishes normally;publisher paused after preflight holds all 16 shard locks,a cross-instance Artifact writer blocks,then observes the durable terminal manifest and leaves no final/partial/marker;publisher paused after journal replay also holds the shared terminal lock,a concurrent `FileDurableJournal` append remains blocked through write-once rename and is rejected after commit;ghost/wrong-size/wrong-hash/final-symlink records all fail before manifest creation,and an injected intermediate-directory substitution is detected by retained directory/file snapshots immediately before rename even when the external tree supplies an equal-size/equal-hash impostor |
| manifest journal authority/attempt binding | `jobCreated.executionAuthority` and `coreBaseline` mismatches both fail before publication;confirmed binding replacements of connectKey,identitySnapshot or evidence fail despite retaining revision 1;Step effect,cancellation and compensationDescriptors changes fail even with the same argumentsHash;attempt 1 succeeded followed by an outstanding attempt 2 cannot publish the old succeeded tuple after audited abandonment;executed Step and outcomeUnknown compensation without any durable attempt both fail before `manifest.json`;the ART-006 positive vector durably records matching intents/outcomes for all three executed typed Steps and its failed compensation |
| manifest graph/policy vectors | previous run covered the recorded whole-graph/policy/journal tuple matrix;current additions reject typed provenance/source-hash mismatch and lineage cycles,and replace the unsafe generic-reconcile positive vector with a stale-snapshot adversarial vector that must preserve unknown,block confirmed terminalization and leave `manifest.json` absent without extending M1-003 semantics;the added vectors type-check and await executable rerun |

## Volume/admission and fault evidence

| Vector | Claim/headroom result | Conclusion |
| --- | --- | --- |
| Session creation admission | missing claim,wrong Job,synthetic wrong volume and finalization-only permit all rejected before Session creation;live same-Job/same-volume metadata claim creates and syncs identity/layout;the same committed claim cannot create a second Session ID/root and creates no second directory;a fresh claim attempting an existing same-Job Session gets EEXIST preflight,does not gain committed binding,and is purged with `activeClaimCount=0`/`reservedBytes=0`;two claims synchronized after the non-atomic ENOENT preflight produce exactly one root winner,the EEXIST loser releases its 201-byte claim,and winner terminal persistence leaves 0 active/0 reserved;faults immediately after root mkdir,at identity file sync,and at directory sync each retain the exact root inode for same-claim repair;a same-path replacement inode is rejected,restoring the original inode permits repair,and durable failed finalization releases to 0 active/0 reserved | Job/Session creation cannot bypass,forge,or permanently leak metadata/finalization headroom on a root race or repairable post-mkdir fault |
| same real volume,different paths | both resolve equal;first heavy admitted;second heavy queued | path strings do not define sharing |
| low water | `100 metadata + 100 finalization + 300 growth`;available `400` | optional growth stops;ENOSPC leaves `200` terminal headroom and active claim |
| concurrency | volume A heavy+bounded light admitted;second A heavy and unknown queued;volume B heavy admitted | serialization is per true volume only |
| external pressure/double-count | soft claim `1,000 → 500` after remaining `800 → 300`;available `499` stops;ENOSPC leaves `200` | update replaces remaining growth;overflow/increase are rejected |
| live growth consumption | 5-byte growth rejects a 6-byte write,then a 4-byte Artifact leaves exactly 1 byte and rejects a second 2-byte Artifact;coordinator reserved bytes immediately reflect 201 | writer and coordinator share one atomic growth ledger;multiple publications cannot exceed it |
| terminal paths | success/throw/cancel finalizers observe active finalization-only claim and uncancelled Task state,release only after durable audit + matching claim-bound Session manifest;dual operation/finalization failure preserves both errors and claim;the same finalizer then repairs its fsync fault and coordinator releases exactly once;wrong-claim receipt is rejected;the `StorageClaimReleasing` adapter releases a repaired receipt once and returns alreadyReleased on retry;reusing the same claimID/Job/disposition creates a new admission generation and stale receipt replay is rejected while the new claim stays active;capacity-2 LRU retains exactly two tombstones,touch preserves the older active retry and evicts the least recently used receipt | optional writers stop before terminal persistence,transient failure is recoverable,completion memory is bounded,and finalization headroom is neither leaked nor released early |
| terminal location binding | different audit/manifest Session roots,a same-Job foreign root used consistently for both audit+manifest,and synthetic replacement volume all fail before terminal receipt;no audit/manifest is written and claim stays active | Job/Session strings alone cannot authorize another claim-bound root or volume |
| remount | same path with synthetic replacement identity | `pauseForVolumeIdentityChange`;no silent continuation |
| destination volume binding | claim A + destination descriptor B and claim A + pre-rename remount B | both return `volumeIdentityChanged`;final path absent |
| diagnostic export admission | live heavy claim on destination volume;light/wrong-volume/1-byte/stopped alternatives | valid claim consumes actual output bytes;all alternatives fail before publication and preserve terminal headroom |
| no-UUID identity | `dev-unverified:4294967295` admits only for initial grouping;first and repeated same-value runtime revalidation return unavailable | finalization-only cannot bypass device-number uncertainty |
| macOS matrix | heavy claim `128 + 128 + 1,024`;second heavy queued;available `200` stops;ENOSPC retains `256`;retry still queued | `PORT-VOLUME-001`/`PORT-STORAGE-001` and `MAC-M1-STORE-001` pass |

Claims in this table are internal admission accounting,not physical disk reservations;the runtime free-space
and ENOSPC vectors explicitly demonstrate that external pressure can invalidate an admitted claim.

## Acceptance conclusions

| Test ID | Evidence class | Binary conclusion |
| --- | --- | --- |
| `TEST-AC-ART-001-01` | contract | passed:Artifact store produced actual ENOSPC;the live claim entered finalization-only,then the production terminal finalizer durably persisted outcome audit + failed manifest while journal/partial remained;status was not succeeded. |
| `TEST-AC-ART-002-01` | contract | passed:raw hash/bytes stayed immutable;derived lineage,parameters and deleted-line statistic were durable. |
| `TEST-AC-ART-003-01` | contract | passed:pre-rename crash exposed no complete final Artifact and left one recognizable partial;cross-instance publication was file-lock serialized;fresh,unmarked-reuse and marked-recovery substitution vectors all rejected pathname inode replacement while retaining descriptor-bound bytes;descriptor-relative publication rejected an intermediate `artifacts` symlink substitution without writing outside the Session;manifest commit held all publication shards,verified every declared file's stable bytes,and a late writer left no final/partial/marker. |
| `TEST-AC-ART-004-01` | contract | passed:archived simulated mode plus fixture/scenario/synthetic provenance survived actual publication/export/reload;an execute-only reinterpretation was rejected by the production manifest validator. |
| `TEST-AC-ART-005-01` | contract | passed:1 GiB input was hashed/referenced with zero Session copy and zero allocated sparse bytes. |
| `TEST-AC-ART-006-01` | platform | passed:macOS filesystem export required a destination-volume heavy claim and growth budget,used the durable manifest list,rejected role forgery,materialized a schema-valid path-aware redacted manifest/App diagnostic/plan with schema-safe constrained identifiers and correct transformed metadata,and excluded device raw/partial bytes by default. |
| `TEST-AC-ART-006-02` | contract | passed:ordinary retention preceded pin;pin remained;descriptor-anchored deletion resisted a concurrent intermediate symlink substitution;unrecoverable margin blocked heavy writer. |
| `TEST-AC-STO-001-01` | platform | passed:same-volume different paths shared one identity/budget and second heavy admission queued. |
| `TEST-AC-STO-002-01` | contract | passed:Session creation required a live same-Job/same-volume metadata claim;missing/stopped/mismatched claims created no Session;an existing-root or racing EEXIST failure granted no terminal binding and released its claim accounting;post-root faults retained only exact-root repair capability;low water stopped optional growth and retained metadata/finalization headroom. |
| `TEST-AC-STO-003-01` | contract | passed:heavy/unknown serialization and bounded light/different-volume concurrency matched policy. |
| `TEST-AC-STO-004-01` | platform | passed:soft claim recheck observed external pressure;remaining update did not double-count;ENOSPC retained completed/partial shards,published failed manifest and failed closed. |
| `TEST-AC-STO-005-01` | platform | passed:all valid terminal paths stopped optional writes then released after durable committed same-root/same-volume persistence;foreign Session Artifact claims and incomplete-creation terminal claims were rejected;root-race losers were purged without a receipt,while three post-root creation fault windows repaired the exact owned inode and then released to zero accounting;transient finalization failure retained headroom,then repaired receipt completion and the existing release seam each released idempotently;replacement identity,root mismatch,wrong receipt and stale receipt replay against a reused claimID retained the active claim. |
| `TEST-MAC-M1-STORE-001` | platform | passed:real macOS identity/probe plus admission,headroom,ENOSPC and remount matrix all passed. |

## Deviations and residual risk

- Allowed-path/cross-deliverable disclosure:`RecoveryManifestContract.swift`、`DurableFiles.swift` 与
  `JournalReplay.swift` 都是 TASK-M1-003 已交付并受版本控制的实现文件,
  不是 TASK-M1-005 新建文件。
  本任务在明确允许的 `Packages/ArkDeckKit/Sources/ArkDeckStorage/**` 范围内修改了这些文件:
  Recovery abandonment timestamp 复用同一 strict RFC 3339 validator,且
  `unexecutedCompensations` 对 raw 声明与 typed policy 做一致性比较；`FileDurableJournal` 现在与
  write-once manifest 共用跨实例 terminal publication lock,在锁内从持有 descriptor 重放最新状态并
  阻止 terminal path 之后的 journal create/repair/append；`DurableJournalRecovery` 增加了同一 descriptor
  的稳定 snapshot 读取,供 writer refresh 与 manifest preflight/revalidation 共用。这些改动只增加
  descriptor/path publication coordination 和 snapshot stability,不改变 M1-003 accepted event schema、
  replay outcome resolution、Job transition graph 或 reconcile decision algorithm。2026-07-18 review
  remediation 明确移除了曾由 TASK-M1-005 引入的 generic reconcile unknown-clearing、
  `lastDurableSequence == sequence - 1` 强化和 historical/unresolved replay view；generic reconcile 继续按
  locked M1-003 语义存在,但 M1-005 Manifest publisher 保守拒绝把任何 durable unknown 解释为 confirmed。
  若未来需要逐项证明并消除 unknown,必须由独立 M1-003 remediation/approved contract 定义。除此之外,
  变更仅涉及 TASK-M1-005 allowed Storage、dedicated test/fixture、本任务状态与本 run evidence。
- The locked manifest validator intentionally mirrors `manifest-1.0.0`;the pinned schema hash and strict
  negative vectors prevent silently accepting future fields.A future schema revision requires an approved
  contract/change and matching validator update.
- Raw read-only mode is a local store guard,not a cryptographic immutability mechanism.An external process
  with user authority could change permissions;ArkDeck publication itself has no overwrite/mutation path and
  manifest SHA-256 exposes such drift.
- Volume UUID is used when the platform exposes it;unsigned `st_dev` fallback is deliberately unverified and
  conservatively stops at runtime revalidation rather than risk device-number reuse after remount.
- Free-form byte substring redaction intentionally ignores identifiers shorter than 4 UTF-8 bytes to prevent
  single-digit/short-token amplification;such values are still redacted when they are exact manifest identity
  fields or exact string values.The evidence therefore does not claim arbitrary short-token substring removal.
  The 64 MiB transformed-output cap additionally makes expansion fail closed rather than allocate unbounded data.
- Artifact publication locks intentionally use blocking `flock`;removing a live lock file would introduce an
  inode-split race,so lock entries remain for the Session lifetime.They are sharded by the first publication-key
  nibble and therefore bounded to 16 files.An ordinary stalled Artifact transaction blocks its shard;terminal
  manifest publication deliberately waits for every shard to obtain a quiescent write-once snapshot.
- Artifact recovery markers intentionally remain while their records are not yet owned by a durable terminal
  manifest.They are bounded to one marker per publication key and are removed with a partial-directory barrier
  during manifest commit;an abandoned Session may therefore retain markers as recovery evidence until Session
  retention removes the whole tree.A marker whose record the terminal manifest does not own is tolerated at
  commit preflight only while its final path is provably absent(the publication never completed);it then
  survives as recovery evidence and roll-forward remains possible by republishing with the completed partial
  as the source.A durable final the manifest omits is still a preflight conflict.Orphaned marker-write
  temporaries(`.publication-marker.*.tmp`)are crash residue and are reclaimed during manifest commit under
  the same descriptor-bound identity guard.
- `FileDurableJournal` pins the journal inode it opened(dev/ino)and every subsequent append/abandonment
  inspection fails closed if the path no longer identifies that inode,so external unlink+recreate or
  rename-over replacement is attributable instead of silently adopted.A lifetime exclusive writer lock was
  deliberately not added:cooperating multi-instance writers on one inode are part of the tested journal
  contract,and in-place same-inode rewriting by a same-uid process therefore remains outside this guard,
  consistent with the raw read-only residual-risk posture above.Every append re-reads and re-validates the
  durable journal under the terminal publication lock;this is O(journal size) per append and is acceptable
  at governed M1 journal sizes,but a size bound or incremental validation should accompany any workload that
  grows journals beyond a few MB.
- Completed-receipt idempotency is intentionally a bounded in-memory window(default 256,touch-on-hit LRU),
  not a durable historical ledger.After eviction an old retry returns `claimUnavailable`;the durable terminal
  manifest/audit remain the long-term completion evidence and a coordinator restart has the same cache boundary.
- The 2026-07-17 executable baseline remains accurately recorded as 51 dedicated tests and a 161-test
  filtered full run.The 2026-07-18 remediation initially could not be executed under the managed execution
  policy;the final 2026-07-18 closeout run(this revision)executed the full suite on a capable host and
  found two remediation vectors that had never run:an audit log-bound fixture opening a nonexistent file
  and a detached-derived lineage assertion expecting the non-redacting transformation label.Both were test
  fixture defects,corrected in this closeout;all currently recorded counts(58 dedicated,29 JournalRecovery,
  169 full)are executed results,not inferences.
- Review closeout(2026-07-18,mechanism freeze)additionally hardened without adding mechanisms:diagnostic
  export validates the durable manifest's Session/Job identity before seeding redaction;the artifact
  publication shard lock re-verifies descriptor↔path inode ownership after `flock` exactly like the terminal
  lock;Artifact publication joins the claim's committed root ownership to the anchored root descriptor;
  `loadUnlocked` applies the same owner/nlink/write-bit metadata checks as sibling opens;marker recovery
  reads share the producer's canonical byte bound constant;anchored directory enumerations rewind their
  duplicated descriptor;the reusable-partial refund precedes its directory barrier;and
  `completeRecoveredFinalization` reports stale-generation receipts with the same admission-generation error
  domain as the release seam.Known accepted residuals:streaming-catch `fstat` failure and the oversized
  derived-provenance marker retain their charge(both fail toward under-budget,never over-budget);
  `terminalManifestExists` treats any directory entry type as published(same-uid availability only);
  retention deletion assumes no live writers per the upstream claim contract and does not itself acquire
  the publication locks.
- Evidence is local contract/macOS platform evidence only.It does not change
  `conformance_status:notStarted`,does not verify hardware/HDC,and does not authorize any release claim.
- TASK-M1-005 remains `Status:ready` with all verification commands executed and recorded in this closeout
  (58 dedicated,29 JournalRecovery,169 full,SDD and diff checks green).That status does not mark the change verified or
  approved,does not change platform conformance,and does not authorize a release or hardware claim.
