# ADR-0007: Runtime artifact 的身份、访问与生命周期

- Status: accepted(CHG-2026-049,2026-07-29)
- Deciders: lvye(merge 即批准)
- Context: MU-3 让 `observe.device@1` 在真机跑通,但产物只存在于 job
  timeline 与 journal 里;HiLog/dump/trace 一旦落地,又会同时触及磁盘、
  隐私与"部分成功如何如实呈现"三个敏感面。需要一次把规则定死。

## Decision

1. **身份由内容决定**。artifact ID 是内容 SHA-256 的前缀,磁盘上的
   文件名就是该 ID。调用方提供的 `name` 只是元数据字段,永不进入路径——
   于是 path traversal 与 symlink 逃逸在这个 API 上**不可表达**,而不是
   "被过滤掉"。相同内容重复发布得到同一 ID(幂等),索引不生重复行。
2. **访问只经 ID/lease**。`artifact.list/inspect/read/export` 的协议面
   没有任何路径参数;`read` 有界;`export` 只接受目标目录、拒绝覆盖、
   对记录名做分隔符清洗。
3. **缺失是一等状态**。声明了却没产出的产物以
   `missing(reason)` 记入索引,并在 `capture-summary.json` 里逐项列出。
   finalize 阶段还有一道兜底:凡"声明了但索引里没有"的产物一律补记
   missing——**不依赖步骤映射的完整性**,因为失败的往往是上游步骤。
4. **上游跳过则下游跳过**。optional 步骤链显式登记依赖;capture 失败时
   receive 不再执行。(此规则由测试抓出的真缺陷催生:trace 采集失败后
   receive 仍"成功"发布了 trace 产物,正是"部分失败被洗白成成功"。)
   下游跳过的原因如实引用上游根因,不复述自身条件。
5. **拒新不毁旧**。配额逼近时拒绝新的发布,绝不驱逐已记录的产物;GC 只
   回收保留期已过、未被 active job 引用且未 pin 的条目。
6. **默认脱敏并留痕**。文本类产物默认替换 token/credential/host path,
   并把 `redactionApplied` 写进元数据——脱敏发生过这件事本身必须可见。
   `sensitive` 产物的读取/导出需要显式 opt-in。

## Consequences

- 采集类 operation 可以安全地"部分成功":调用方读 summary 就知道缺了
  什么、为什么缺,不必反推。
- 存储面的攻击面收窄为"引擎给的 jobID"一处,且该处也有格式校验。
- 迁移成本低:artifact 目录是全新结构,既有 session/manifest 存储不动。

## Alternatives considered

- **沿用调用方给的文件名**:被否——那要求每处都记得做路径清洗,是典型
  的"修一处漏一处"形态。
- **缺失就不写索引**:被否——正是这种沉默让部分失败看起来像全成功。
- **配额满时淘汰旧产物**:被否——刚采集的证据可能正是要保住的那份。
