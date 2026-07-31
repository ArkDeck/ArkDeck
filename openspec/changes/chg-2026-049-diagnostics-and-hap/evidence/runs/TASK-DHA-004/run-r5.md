# TASK-DHA-004 run — 屏幕截图文件型产物(2026-07-31)

## 结论

- DHA-SHOT-001、002、003:**全部 PASS**(contract + 真机同车)
- 顺带修掉一个 **r2 带进来的洞**(见下),并补了对应回归测试

## 真机执行

| 项 | 值 |
| --- | --- |
| 设备 | DAYU200,`TGT-958780b2ffb7`,hdc 3.2.0f |
| 入口 | `arkdeck agent run --operation capture.diagnostics@1`(executor=agent) |
| Inputs | `durationSeconds: 3`、`uiDump: true`、**`uiScreenshot: true`** |
| Job | `job-27e4878abde3c50814b6a788929e94a5`,`succeeded`,`actualEffect: E1`,`humanActions: []` |

```text
verified capture-screenshot     ["remoteByteCount"]
verified receive-screenshot     ["byteCount", "localArtifact", "sha256"]
artifact screenshot.png -> ART-88465d3c509a8b5ee4a144c43958f7cc
verified cleanup-screenshot-temp ["cleaned"]
```

产物导出后校验:**449,756 字节,魔数 `89 50 4E 47 0D 0A 1A 0A`,尺寸 720×1280** ——
与设备屏幕一致。未请求的 `ui-tree.json` 与 `trace.htrace` 如实记 missing。
窗口结束设备 `/data/local/tmp` 无 `arkdeck-*` 残留。

## 命令形态更正(事实表 §8)

```text
-f <x>.png          -> error: fileName … invalid, suffix must be .jpeg
-f <x>.jpeg         -> file type: jpeg,  40,941 B
-t png -f <x>.png   -> file type: png,  449,830 B
usage: snapshot_display [-i displayId] [-f output_file] [-w width] [-h height] [-t type] [-m]
```

`-t png` 是**必需**而非重试;设备按文件名后缀校验类型,所以 provider 铸的
owned path 后缀 `.png` 是判据的一部分,不是装饰。§8 随本 PR 更正。

## 计划外:补上 r2 漏登记的依赖

`optionalStepUpstream` 是一张**显式**的"下游步骤依赖哪个上游"表,用来防止
"上游没跑,下游却产出产物"。r2 加组件树三条腿时**没有登记**,于是
`capture-ui-tree` 判失败后 `receive-ui-tree` 仍会跑、仍会发布 —— 一个凭空产生的
产物。本次加截图腿时被同一条测试打出来。

修复:把组件树与截图两组腿全部登记,并补
`testFailedComponentTreeCaptureSkipsItsReceive` 钉死组件树那半。

**这类"新腿必须登记进某张显式表"的洞,本轮已经是第二次**(上次是 D12 的
cleanup 债务键)。表本身是对的设计——显式优于推断——但加腿时要逐张过一遍。

## 本记录**不**证明的事

- 不声称任何 `DHA-HW-*` AC 通过;
- 只验证 PNG 形态;JPEG 与 `-w/-h` 缩放按 r5 的 out of scope 未做;
- 单显示屏设备,`-i displayId` 多屏行为未验证;
- `-m` 参数语义未探。
