# Evidence — CHG-2026-075

本目录当前只有执行约定，没有实现或真机通过记录。
每个任务在自己的实现/验收 PR 中追加 runs/TASK-SVC-NNN/run.md，包含：

- 完整 base/head OID、实际变更范围、执行命令、退出码和必要输出链接；
- 对应 SVC-AC 的逐项结果，未执行项与具体原因；
- fixture/fake/host、App呈现检查、real-device结果明确分类；
- 版本清理残留命中及保留理由，当前方法映射与consumer覆盖结论；
- 真实运行的Runtime记录引用、Catalog digest和允许公开的redacted元数据。

原始 Artifact/hardware evidence不原地修改，secret不进入日志。
运行命令、测试产物或schema通过不构成真实设备证据，不把旧Catalog结果重标为当前PASS。
