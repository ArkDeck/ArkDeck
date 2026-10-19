# 真实反复重启故障专项验收（2026-10-19）

本专项补充已完成的 [独立入口验收](independent-acceptance-20261019.md)。该记录证明了
Normal/HDC 下的原 ramdisk 恢复与独立完整哈希读取；它没有注入真实反复重启故障。
本专项已执行首轮试验并安全恢复，但尚未证明真实反复重启，不据此新增硬件支持声明。

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

## 首轮试验与恢复

首轮使用 protected `main` `3142957cd6e11ac46c5f0b4fb97a45625df441d7` 的签名 Runtime，
Catalog 为 `fe0806a5756ae59d55410a976039d2cd1853105f6d7d1f5aa00473026a81ed18`。
源 Job `job-7bfca2efe613801268f68b41ce562038` 完成九分区写入，结果 confirmed、无 unknown，
但 Session 发布为 `sourceIntegrityFailed`：观测时间 `08:00:11Z` 晚于 capability 消费时间
`07:55:43Z`。后续只读快照在 uptime 195.530 秒时未发现故障控制器，不能证明所需重启。
这两项失败均保留原始 Runtime 记录；不将源 Job 或本轮试验记为专项通过。

随后由 Runtime 根据该实际源的完整机械证明准入独立恢复 Job
`job-fe34cac737c09fa274d14616d1b27c4e`，仅恢复原始 ramdisk 范围
`121634816 + 4194304` 字节，完整哈希为
`bdd1f4eacbe545f5a553b529980bc487723d37554148058dd551c241abf86de4`。
独立验证 Job `job-2f7b7b6d28cb4f52a15d7cfcd0d3079f` 返回 exit 0、verified 1、
skipped 0、failed 0，两者 Session 均已发布。恢复后的两个只读快照无故障标记，保持同一
boot ID，实际观测间隔 254.208 秒、uptime 增长 254.240 秒。Runtime 审计确认本轮仅有
两个新 capability，各消费一次；旧 capability、allocation 和历史 Job 字节保持不变。

本次普通修复补齐 HDC Normal 模式 FullFlash 的准入前机读观测，并保留该观测供 Session
校验；刷后的型号、版本仍由实际 postflight receipt 发布为 `post-flash-facts.json`。
观测缺失、身份或路由漂移、空元数据在消费前停止。Session 的时间顺序校验、Catalog、
destructive policy、历史 fixture 和设备写入范围均不放宽。新的完整故障验收仍待执行。

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

FullFlash 准入前观测修复的日志保存在本机 `flash-preflight-checks-20261019/`：

- 推进时钟的 FullFlash 回归先复现 `sourceIntegrityFailed`，修复后 exit 0；完整策略
  定向测试 9 passed，最终 FullFlash 边界 2 passed，recommission/controlled retry 边界
  12 passed，均 exit 0。日志 `full-restore-clock-red.log`、`flash-policy-final.log`、
  `full-restore-boundary-final.log`、`recommission-boundary-final.log`。
- Hoststore 与直接依赖 Agentd、Soak 的库测试 exit 0；Hoststore 为 428 passed、5 ignored，
  另两者各 3 passed。相同三个 crate 的 `clippy --all-targets -- -D warnings` exit 0。
  日志 `lib-*-final.log`、`clippy-boundary-final.log`。
- 官方 `fmt --all --check` 仍受 Windows argv 206 限制；全部 358 个相同 workspace
  target 根的分批 `rustfmt --check` exit 0。日志 `fmt-all-native.log`、
  `fmt-batched-native.log`。Catalog 路由检查 36 passed、exit 0，原 fixture inventory
  逐字节一致；新加两项回归注册到现有 policy 视图。日志 `catalog-views-native.log`。
- SDD 检查 exit 0，0 errors、0 warnings、121 acceptance IDs；`git diff --check` exit 0。
  受限 Temp 无法创建检查目录、受限 shell 无法启动的原始失败日志保留，改用正常本机环境
  执行同一检查后通过，未放宽断言。日志 `sdd-native.log`。

## CI

观测能力 [PR #2678](https://github.com/ArkDeck/ArkDeck/pull/2678) 的首轮
`39197939838` 在契约输入指纹与 Windows App 投影一致性检查失败；已按实际错误同步生成物，
未修改断言。修复 head 的 CI 结论待实际完成后记录。CI 成功与 host fixture 均不替代
本专项的真实设备结果。

同 PR 的 `39198677397` 已通过主机检查、Windows ClientKit、App 构建、Linux workspace
和 Linux contract parity；Swift 的显式 remote-read 集合与历史输入兼容测试的版本清单
尚未覆盖新 Catalog。后续提交加入明确的 `bootContext` 集合项和上述完整摘要证明，
保持未知 action、未知 Catalog 和旧输入字段拒绝条件，继续由 CI 验证。

`39200798439` 的 Swift、App、Windows ClientKit、主机检查、三平台 workspace 和
Linux/macOS contract parity 均成功。Windows contract parity 被 100 分钟 job 上限取消：
自动保留的 provenance 证明 published、candidate、historical 三视图完整通过，observed
视图在最后一组单测中被截断，日志没有断言失败。该用例在前三视图均成功；published
和 historical workspace 各约 28–29 分钟，candidate consumer 约 10 分钟，observed
又执行约 26 分钟后被截断。本次输入差异
需要完整四视图，因此 Windows 该 job 预算调整为 120 分钟；精确预算校验及 121 分钟
拒绝用例同步更新，全部产品/契约用例、断言和设备 Runtime 预算保持原样。最后的
Session 用例本机单跑 exit 0（25.61 秒），日志 `session-publication-isolated-budget-120.log`。
新 head 的完整结论仍需 CI 实际给出。

最终 head `b6982762097028d004389cfed42ae5c694063522` 的
[Swift CI 39211002240](https://github.com/ArkDeck/ArkDeck/actions/runs/39211002240) 全部成功，
包括 Windows contract parity（55 分 50 秒）、macOS contract parity（53 分 18 秒）、三平台
workspace、Swift、App 和 Windows ClientKit；SDD Guard `39211002214` 成功。
PR #2678 已合入上述 protected main。真实故障专项仍以独立设备完成条件为准。
