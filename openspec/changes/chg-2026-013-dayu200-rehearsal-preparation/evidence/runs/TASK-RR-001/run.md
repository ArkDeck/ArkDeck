# TASK-RR-001 run — DAYU200 演练准备(host-only,设备不在场)

- Change:CHG-2026-013-dayu200-rehearsal-preparation / Task:TASK-RR-001
- 执行日期:2026-07-18;执行主机=演练主机(macOS 26.5.2/25F84,arm64,
  Apple clang 21.0.0);执行者:Agent(host 命令),操作者(维护者
  fuhanfeng)提供设备断开书面确认
- **设备不在场 attestation**:操作者于执行前在会话中书面确认 DAYU200 已从
  演练主机断开;`ld` 采集零设备枚举行佐证;全程无任何设备交互
- 交付物:`../../prep-record.md`、`../../rehearsal-record-template.md`
- 命令面:全部在 proposal「Execution boundary」封闭白名单内——brew(跳过,
  依赖已在位)、git clone×2(官方 upstream+radxa fork 诊断用)、autoreconf/
  configure/make、shasum、tar、产物 `-v`/`--help`/`ld`;逐命令 argv/输出/exit
  记录于 prep-record;白名单外命令:0

## 二值结论(per acceptance-cases.yaml)

| Test ID | 结论 | 依据 |
| --- | --- | --- |
| TEST-PREP-DAYU200-TOOLING-001 | PASS | rkdeveloptool 自官方 upstream(commit `304f0737…`)构建成功,产物 SHA-256 `038a8a0e…3611` 在案;`-v`=`ver 1.32` 达标 ≥1.32;无设备 `ld` byte-exact 采集为 `not found any devices!` 零枚举行;判定全程按输出标记非退出码(`ld` exit=1 如实记录);设备全程不在场 |
| TEST-PREP-DAYU200-MATERIALS-001 | PASS | pinned 归档全量重算 732948803 bytes/`fc7637…5280` 与 archive-identity 逐字节一致;17/17 成员逐文件全量 SHA-256 vs archived member-inventory.json 全 MATCH 0 FAIL;物料字节留仓库外(`~/dayu200-rehearsal/`);模板含逐命令栏位、预案 §5 中止准则原文、§6 检查单打勾页与 P 前置检查节 |

## 偏差 / 发现

- **F1(环境陷阱,入模板 P4)**:PATH 上 OpenHarmony SDK toolchains 的非
  POSIX `diff`(对不存在文件对 exit 0)使 autoconf header 生成静默失败
  (upstream 与 radxa fork 双复现);净化 PATH 后即正常。演练主机执行任何
  构建/脚本须先净化 PATH——退出码不可信教训(M0A/M0B 同族)的环境版。
- F2:上游 `-Wall -Werror` 遇 Apple clang 21 `-Wvla-cxx-extension` 报错;以
  `make CXXFLAGS="-g -O2 -Wno-vla-cxx-extension"` 构建,零源码修改。
- F3:`ld` 无设备场景 exit=1(输出正常)——判定按输出标记的又一实证。
- 白名单"brew install"分支未走(依赖已全数在位),如实记录。
- radxa fork 克隆仅用于 F1 交叉诊断,未用于最终构建产物。

## Boundary

host-only、设备不在场;本 run 使检查单第 1/2 项与第 6 项模板部分**具备打勾
evidence**,打勾动作属未来演练 change 立项时;不勾第 3(PD-001)/4(风险
确认)/5(时间窗)项;不立项演练、不构成演练执行授权;不解除任何 gap;
DEC-002 不变;`done` 翻转由独立状态 PR 执行。
