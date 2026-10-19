# 真实反复重启故障专项验收（2026-10-19）

本专项补充已完成的 [独立入口验收](independent-acceptance-20261019.md)。该记录证明了
Normal/HDC 下的原 ramdisk 恢复与独立完整哈希读取；它没有注入真实反复重启故障。
本专项尚未完成真机执行，不据此新增硬件支持声明。

## 观测能力

`observe.device@1` 增加 `includeBootContext`，默认 `false`。只有显式选择 `true` 时，
精确绑定的 HDC Provider 才执行固定、只读、有时间和字节预算的 `bootContext` 读取。
该步骤被选择后必须成功；读失败、输出不完整、boot ID 在读取期间变化、故障报告与
当前 boot ID 不一致、报告重复或不符合 RAM 文件约束，均不能发布成功快照。

`boot-context.json` 是本地敏感 Artifact，关联当前 Job、Catalog、设备身份和实际读取
时间窗，包含 kernel boot ID、uptime、idle time，以及可选的 RAM 故障标记。故障标记
只从固定控制器持有的 root 所有、权限 `0400`、大小受限的 RAM 文件描述符读取；调用方
不能提交路径、命令或预期观测值。快照和故障标记不承担 capability authority。

未选择时保留既有设备调用。新 Catalog 对 `observe.device@1` 作兼容增量，Flash 与
恢复 operation、destructive policy 和原始历史记录保持不变。历史 c6/e4 测试仍使用
完整的冻结 Catalog；新快照集成用例仅进入声明此能力的 Catalog 视图。

## 本次故障与完成条件

用户选择了真实自动反复重启、每轮保留短暂 HDC 观测窗口的路径。本次计划在原 ramdisk
的派生镜像中保留原 `bin/init_early`，由独立 RAM 控制器在 kernel uptime 达到 180 秒
时触发重启。每轮启动都会重新运行控制器；恢复原 ramdisk 后移除该行为。原镜像不改写，
派生过程保留源哈希、控制器哈希、参数及完整归档成员校验。

当前已发布 Flash 入口的写入范围是完整九分区，包括 `userdata`；故障归档仅替换
`ramdisk.img`，其余归档成员与原件逐项相同。设备写入只经 protected-main Runtime 的
typed operation，capability 仍由 Runtime 根据完整物化计划和 fresh trusted facts 生成、
reserve、consume。主机输入构建不构成设备验收。

完成本专项需要实际取得：

1. 当前发布 Catalog 上的完整九分区源 Flash confirmed receipts，且不存在 unknown。
2. 同一设备、同一故障 nonce 下至少三个不同 boot ID 的 Runtime 快照，证明至少两次
   自动重启；每个快照均有实际读取的 Artifact 和独立 Job 记录。
3. `flash.restore-boot-loop@1` 对该源执行独立恢复，实际只恢复完整原始 4 MiB ramdisk，
   并以 full hash 验证成功；新 capability 精确匹配且仅消费一次。
4. 独立 `flash.verify@1` 返回 ramdisk 完整哈希成功；恢复后的两次 Runtime 启动快照
   不再带故障标记、保持同一 boot ID，观测间隔超过 180 秒并留出余量。
5. 相关公开 result/evidence 和 Session 发布成功，原历史、旧 capability 与旧 allocation
   不改写。任何 unknown 或缺失的恢复证明均按现行安全策略停止受影响的写入。

本专项覆盖所选的 HDC 窗口路径，不代表启动早期 HDC 完全不可达或 Loader/MaskRom 路径
已经验收。实际 Job、Artifact 哈希和执行结论将在真机运行后补记。

## Local targeted checks

所有日志仅保存在本机 `boot-context-checks-20261019/`，不导出原始设备数据：

- `python rust/scripts/run-cargo.py test -p <crate> --lib`：修改 crate 与直接依赖共 11 个
  crate 全部 exit 0；Hoststore 428 passed、5 ignored。日志 `lib-*-catalog-pins.log`。
- `python rust/scripts/run-cargo.py clippy -p <crate> --all-targets -- -D warnings`：同一组
  crate exit 0，日志 `clippy-final.log`。
- Provider `--lib boot_context::` 三项与 Runtime `--test windows_observe_device_commandless`
  五项均 exit 0，日志 `provider-boot-final.log`、`runtime-boot-final.log`。覆盖默认调用不变、
  实际 Artifact 字节与哈希、敏感读取、畸形和跨 boot 快照拒绝。
- CLI `--test machine_contracts --test maintainer_contracts` exit 0，日志
  `cli-machine-final.log`；官方契约 export 的 244 个产物仅两个 Catalog digest 投影改变。
  App 的离线 Flash 投影也由官方 `flash_catalog_review` example 重生成。
- Catalog generator 49 项与相关 Python 聚焦检查 73 项 exit 0，日志
  `catalog-generator-schema-fixed.log`、`python-focused-initial.log`。完整 Python 检查的
  78 项中 76 passed、1 skipped、1 因 Windows 的 POSIX mode 表现为 `0777` 而非 `0700`
  失败，保留在 `contract-checks-schema-fixed.log`，未修改该断言或将其记为通过。
- `python rust/scripts/run-cargo.py fmt --all --check` 遇到 Windows argv 长度错误 206；
  同覆盖范围的分批 `rustfmt --check` exit 0，日志 `fmt-all-final.log`、
  `fmt-batched-final.log`。
- `sh scripts/check-sdd.sh` exit 0，0 errors、0 warnings、121 acceptance IDs，日志
  `sdd-final.log`；`git diff --check` exit 0。
- CI 发现两处生成物 drift 后，官方 `generate-contract.py --write`、`--check` 均 exit 0，
  仅更新输入指纹，110 个 control methods、1085 个 recorded shapes 和 contract identity
  保持不变。Windows JSON 从官方 Swift Flash 投影同步，单跑
  `TheCatalogReviewIsTheOneTheMacOsAppCompilesIn` 一项 exit 0。日志
  `contract-*-ci-fix.log`、`windows-projection-test-ci-fix.log`。
- 新 Catalog 的完整输入兼容证明单跑 exit 0，日志 `compatibility-ci-fix.log`：先核对完整
  新 Catalog 的精确摘要，再仅以旧 `observe.device@1` 替换新描述符，要求完整表恢复为
  已发布的前一 Catalog 摘要，随后继续逐项比较全部 32 个旧描述符。旧 fixture 不修改。

本机未执行 SwiftPM、macOS App build-for-testing 或本地统一门；Windows 只单跑了上述
离线投影检查。

## CI

观测能力 [PR #2678](https://github.com/ArkDeck/ArkDeck/pull/2678) 的首轮
`39197939838` 在契约输入指纹与 Windows App 投影一致性检查失败；已按实际错误同步生成物，
未修改断言。修复 head 的 CI 结论待实际完成后记录。CI 成功与 host fixture 均不替代
本专项的真实设备结果。

同 PR 的 `39198677397` 已通过主机检查、Windows ClientKit、App 构建、Linux workspace
和 Linux contract parity；Swift 的显式 remote-read 集合与历史输入兼容测试的版本清单
尚未覆盖新 Catalog。后续提交加入明确的 `bootContext` 集合项和上述完整摘要证明，
保持未知 action、未知 Catalog 和旧输入字段拒绝条件，继续由 CI 验证。
