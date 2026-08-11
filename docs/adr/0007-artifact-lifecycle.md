# ADR-0007: Runtime artifact 的身份、访问与生命周期

- Status: accepted(CHG-2026-049,2026-07-29)
- Deciders: lvye(merge 即批准)
- Context: MU-3 让 `observe.device@1` 在真机跑通,但产物只存在于 job
  timeline 与 journal 里;HiLog/dump/trace 一旦落地,又会同时触及磁盘、
  隐私与"部分成功如何如实呈现"三个敏感面。需要一次把规则定死。

## Decision

1. **身份绑定不可变发布语义**。artifact ID 由 job ID、声明名与内容
   SHA-256 共同派生,磁盘文件名只使用该 ID。这样相同字节但不同声明产物
   不会碰撞,同一 job 内同名产物也不能用不同字节覆盖;完全相同的重试则
   幂等返回原记录。调用方提供的 `name` 只进入元数据,永不直接进入路径。
   ~~首版 MU-4 已产生的 16-hex ID 保持只读兼容和幂等重开;新发布统一使用
   32-hex identity,不破坏已落盘 daemon 状态。~~(2026-08-11 退役,见文末修订)
2. **访问只经 ID/lease**。`artifact.list/inspect/read/export` 的协议面
   没有任意源路径参数;`read` 有界;`export` 只接受目标目录、拒绝覆盖、
   对记录名做分隔符清洗。跨 operation 输入使用不含 host 路径的
   `lease-v1:<jobID>:<artifactID>`,store 解析时重新校验普通文件、大小与
   SHA-256,provider 只得到解析后的 typed artifact。
3. **缺失是一等状态**。声明了却没产出的产物以
   `missing(reason)` 记入索引,并在 `capture-summary.json` 里逐项列出。
   finalize 阶段还有一道兜底:凡"声明了但索引里没有"的产物一律补记
   missing——**不依赖步骤映射的完整性**,因为失败的往往是上游步骤。
4. **上游跳过则下游跳过**。optional 步骤链显式登记依赖;capture 失败时
   receive 不再执行。(此规则由测试抓出的真缺陷催生:trace 采集失败后
   receive 仍"成功"发布了 trace 产物,正是"部分失败被洗白成成功"。)
   下游跳过的原因如实引用上游根因,不复述自身条件。
5. **拒新不毁旧**。采集在任何 device dispatch 前按本 job byte budget
   做 host quota preflight,配额不足即拒绝;发布时再次检查,绝不驱逐已记录
   的产物。GC 只回收保留期已过、未被 active job 引用且未 pin 的条目,
   且以解析后的 UTC 时间比较而非字符串顺序。`default`
   保留 7 天、`shortLived` 保留 24 小时、`pinnedUntilVerified` 无自动
   deadline;发布时把计算后的绝对 UTC deadline 写进元数据。
6. **默认脱敏并留痕**。文本类产物默认替换 token/credential/host path,
   并把 `redactionApplied` 写进元数据——脱敏发生过这件事本身必须可见。
   `sensitive` 产物的读取/导出需要显式 opt-in。
7. **目录与索引也 fail closed**。artifact root、job 目录、export 目录及
   已发布文件不得是 symlink;索引重开时重新校验 job/ID、唯一 name/ID、
   大小与 hash。索引或磁盘漂移不会被当成可读 artifact。

## Consequences

- 采集类 operation 可以安全地"部分成功":调用方读 summary 就知道缺了
  什么、为什么缺,不必反推。
- 存储面的攻击面收窄为引擎给出的 jobID/ID/lease,三者均做闭集格式和
  磁盘一致性校验。
- 迁移成本低:既有 session/manifest 存储不动;首版短 ID 无需离线迁移。

## Alternatives considered

- **沿用调用方给的文件名**:被否——那要求每处都记得做路径清洗,是典型
  的"修一处漏一处"形态。
- **缺失就不写索引**:被否——正是这种沉默让部分失败看起来像全成功。
- **配额满时淘汰旧产物**:被否——刚采集的证据可能正是要保住的那份。

## Amendment(2026-08-11)

- **16-hex 只读兼容面退役**。Decision 第 1 条为首版 MU-4 短 ID 保留的
  只读兼容与幂等重开,在存量审计后移除:对唯一生产 daemon 状态的逐面
  检查(runtime job 记录 1493 处、harness snapshot 5658 处、artifact
  索引 1595 处 ID 引用)显示 16-hex ID 存量为零——该世代从未在真实
  数据中落盘存活。`isSafeArtifactID` 自此只接受 32-hex identity;索引里
  出现 16-hex ID 按索引损坏 fail loud 拒绝,不再静默视作同一发布。
  当年"不破坏已落盘 daemon 状态"的约束对象已不存在,故本修订不构成
  对既有状态的破坏。落地见 PR #1259。
