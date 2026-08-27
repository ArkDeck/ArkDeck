# Device 真机走查 · 2026-08-27

本记录对应 GJ-1 的设备观察和 GJ-2 的真机输入／采集子链路，不代表整个 Golden Journey 验收完成。**App 录屏仍为 `BLOCKED_BY_PRODUCT_DEFECT`**：本轮已修复源码，但已安装受保护 Runtime 的 XPC 入口尚未更新。不得把下列 CLI 成功、fixture 回放或 HTML ready 状态合并成 App 录屏成功。

## 环境与证据位置

- 设备：OpenHarmony 3.2；固件 OpenHarmony-7.0.0.38；720×1280；USB；脱敏目标 `TGT-…ffb7`，binding r4，与用户原始截图对应。身份和 binding 由 Runtime 重新读取，不由测试构造。
- 工具：HDC 3.2.0f；使用既有签名 main CLI 与已安装 Runtime，未替换 daemon。CLI 构建来自 main 提交 `6e7bf486963f9b924e1498ce9a6b69e79765105f`。
- Runtime 与本工作树的已发布 Catalog digest 相同：`b8c7148fc7cd9f7a413167262a6d44bf35e049a62a94613f3a94248ab08784ce`。
- 原始回执、状态、制品索引与导出文件仅在本机 `/private/tmp/arkdeck-device-real-20260827/`。真实截图、帧归档和桌面测试附件未加入 Git、未上传。
- 所有设备效果走已发布 typed operation；没有 raw HDC、修改 capability、清空历史、重放 unknown 或替换设备身份。

## CLI 真实执行

| 操作 | Job | 观察结果 |
| --- | --- | --- |
| PNG 截图 | `job-4703017083aeb1354f78044b154cbd5d` | succeeded；720×1280 PNG；capture/receive/cleanup 已确认 |
| 上滑 | `job-d24c528aaf859faa884fa8b557903cb2` | succeeded；(360,1030) → (360,430)，600 ms；inject-pointer-input 已确认 |
| 重新截图 | `job-72c9e516bf511e96df2f2b51f5811576` | succeeded；画面从锁屏变为设置页的 USB 弹窗 |
| 点击 | `job-dd77610e152f229a7337de8d17c05fb2` | succeeded；(360,800) 确认原有“仅充电”选择，未开启文件／图片传输 |
| 长按 | `job-863cb5e431fb03720b48ca019ae6059f` | succeeded；设置标题区 (360,102)，650 ms；Runtime 已确认输入，无 unknown |
| 40 帧采集 | `job-feed707f8bcfdbfff503dfc848ad701f` | succeeded；40/40 帧，missing=0，24.793 秒，1.613358609 fps；receive/cleanup 已确认 |

以上 Job 的 `executionMode=execute`、`outcomeUnknown=false`、无未清理残留，mutation 消费 Runtime-owned capability。截图和输入的持久 Job 确认成功，但旧 Runtime 的 evidence 回执各有一处错误阻断，见后文；原回执保留不改。

长按的首次请求遇到 App 尚持有的设备会话，Runtime 以 `deviceBusyBySession` 在创建 Job 前拒绝，零 dispatch。等最后一次 App 操作自然空闲超过 120 秒后，新的请求重新准入成功；没有伪装 client、主动释放 hold 或重放 unknown。

40 帧采集于 07:14:52–07:15:18 UTC。回执 `evidenceBlockers=[]`，两份制品均由 Runtime 验证字节；导出后再次计算 SHA-256 一致：

| 制品 | 字节 | SHA-256 |
| --- | ---: | --- |
| `frames.tar` / `ART-21922aff77e6ef07d7eed8b420e587dd` | 1,947,136 | `c84d5aa89ce31ddb7dac83ba4b5f2d1431f0ca4d29038a39c7f33c9d900e6bcb` |
| `sequence.json` / `ART-08875018444e41ae94aab04bf608bc1e` | 634 | `fc442bb4c92cc093f18a7ae042c738d0e9c4c58dbfa310b12a9726bc77bf2d53` |
| 初次 `screenshot.png` / `ART-d61868b37664583f815233501aeeac24` | 448,873 | `460480429b7e91fab05dab380bcfe1a3e8f503a39e5bc117325d1109c7924609` |

## 原生 App 真实执行

最终有效 UI 运行：`/private/tmp/arkdeck-device-real-ui-retry-20260827.xcresult`，日志同名 `.log`。没有 `--ui-test-devices`、`--ui-test-device-recording`、配额 fixture 或模拟截图；App 通过 XPC 请求已安装 Runtime。

- `DeviceStaleFrameUITests/testASecondPressOnASpentPictureIsRefusedAndNotSent`：**通过，25.269 秒**。真实截图 → 设置标题区一次已确认点击 → stale → 第二次点击本地拒绝、等待 8 秒无新结果 → 重新截图清除 stale。使用已观察的安全位置 `(0.5, 0.08)`，按实际图像矩形定位，不盲点窗口中心。导航、标题和手机图标均已显示 Device。
- `DeviceRecordingUITests/testRealDeviceRecordingCapturesFortyFramesAndOffersALocalMovie`：**失败，10.301 秒**。准确错误为 `Device submission failed: Runtime transport refused this request: methodNotAllowlisted`。没有开始真实录屏、没有生成 `.mov`，没有将失败改成 skip。
- 前一轮截图输入断言错误地读取 macOS StaticText 的空 `label`；截图显示 `Tap · confirmed`，修正为读取 `value` 后上述测试通过，未放宽业务断言。
- 首轮未向 runner 传入真机开关而跳过，以及一次启用 macOS automation 超时，均不计入真实通过结果。

最终这次 App 测试在 Runtime 中只留下两次截图和一次点击：`job-559d7a2e44d482985038ceb14dabc273`、`job-482e915f0ec9a07f2e75269e34446b0f`、`job-4cc6118f1700b39560c60dcddfd34c8c`，均为 succeeded、无 unknown、残留 0。拒绝的第二次点击没有新 Job；录屏也没有 Job。原始截图附件位于 `/private/tmp/arkdeck-device-real-ui-retry-attachments/`。

正确传入 runner 环境的命令如下；安全落点必须在新运行前由可见画面确认，不能照抄到未知界面：

```sh
TEST_RUNNER_ARKDECK_UI_TEST_DEVICE_REAL_DEVICE=1 \
TEST_RUNNER_ARKDECK_UI_TEST_DEVICE_TAP_UNIT_X=0.5 \
TEST_RUNNER_ARKDECK_UI_TEST_DEVICE_TAP_UNIT_Y=0.08 \
sh scripts/ci/run-ui-tests.sh \
  -only-testing:ArkDeckHDCUITests/DeviceStaleFrameUITests \
  -only-testing:ArkDeckHDCUITests/DeviceRecordingUITests/testRealDeviceRecordingCapturesFortyFramesAndOffersALocalMovie
```

## 同车修复与剩余验证

1. **App 录屏漏接 XPC**：补齐 `ArkDeckApp.Toolkit.DeviceControl` 与 `capture.screen-sequence@1` 的精确入口，继续使用既有一次性 Job gate 和 Runtime 准入；其他 client、缺失／错误 version 仍拒绝。实际 facade 请求的回归测试先复现失败，修复后 XPC 契约 11 项通过。
2. **截图回执要求未选择的编码**：只选择 PNG 时旧 Runtime 仍要求 JPEG。现在使用持久化输入和既有 publication encoding selection 判定 omission；选中的图片缺失或损坏仍阻断，不改历史制品。
3. **输入回执要求文件**：已发布输入操作没有制品，旧 Runtime 仍要求非空 Artifact index。现在仅当 published descriptor 明确零制品且 inventory 为空时接受空文件证据；存在的 metadata 继续完整校验。截图、输入、制品与编码相关回归 120 项通过（1 项独立硬件 opt-in 跳过），属于测试替身验证，不是新 Runtime 的真机验证。

剩余依赖：维护者 review 合入 main 并更新受保护 Runtime 后，重跑 App 40 帧录制，核对真实 Job、sequence timing、`.mov` 尺寸／时长／可读性、结果动作和截图／输入回执。不安装未审核 daemon、不伪造 clean receipt，也不把 HTML 演示作为替代。

## 最终本地回归

```sh
ARKDECK_TEST_WORKERS=4 python3 scripts/ci/plan.py \
  --repo-root . --base-revision origin/main --head-revision HEAD \
  --merge-base --include-worktree --run-local
```

退出码 **0**；日志 `/private/tmp/arkdeck-device-real-final-ci-workers4.log`：SDD 0 error / 0 warning；Catalog generator 49 项、零漂移、SwiftPM runner 10 项通过；Swift 全量并行 1,797 项、串行 process identity 1 项、viewer scale 5 项通过；App/UI-test bundle `TEST BUILD SUCCEEDED`。构建 UI 测试包不等于 UI 断言通过，上面的 App 真机录屏失败仍保留。

默认并行度的首轮全量运行在三个未改动的 `PersistentDeviceShellChannelContractTests` 上发生 shell 启动超时；同组 7 项单独运行通过，再以现有 `ARKDECK_TEST_WORKERS=4` 配置重跑全部车道通过。没有修改断言、超时或测试选择范围。

交互稿 Node 状态机测试 **12 项通过**，包含 Runtime 未接通时零采集／零结果；token 校验与 `git diff --check` 通过。新增失败场景还经过内置浏览器实际点击走查，原始参考图为 `device-runtime-unavailable-zh-Hans.jpg`，仍是演示数据。
