# ArkDeck Trace 采集、解析与 Timeline 使用指南

> Status：current（2026-08-24）
> 产品规格：[`arktrace-migration-spec.md`](./arktrace-migration-spec.md)
> Parser 来源与构建：[`arktrace-trace-streamer.md`](./arktrace-trace-streamer.md)

ArkDeck 只有一条 Trace 产品路径：设备工作由已发布的 `capture.diagnostics@1`
Runtime operation 执行；不可变 Artifact 通过 Artifact API 有界读取，同时校验字节数和
SHA-256，之后才在本机解析。Viewer 与 `arktrace` helper 都不执行 HDC，也不接受
shell 命令。

## 打开已有 Trace

可以使用 **Trace → Open Trace…**、Finder 的「打开方式」、拖放或最近文档。ArkDeck
识别 `.htrace`、`.ftrace`、`.systrace` 和 `.trace`。只有源文件验证、parser identity
验证、数据库准备与首份 Viewer snapshot 全部成功，新文档才会替换当前文档。

首次解析需要生成 content-addressed SQLite 与索引，可能更慢。只有 source hash、
parser identity、schema adapter 与 cache metadata 同时相等时才复用 Ready cache。
Trace 缓存设置位于标准 macOS Settings 窗口。

## 从 App 采集

1. 打开 **Trace** 工作区，选择 Runtime 返回的精确 target 与 binding。
2. 刷新 probe，只选择该 target 当前确认支持的 tags。
3. 在已发布的 operation 边界内输入 duration：可以按秒或分钟输入；秒提供
   `15s`、`30s`、`45s`、`60s` 快捷项，分钟提供 `1 min`、`2 min`、`3 min`
   快捷项。界面最终只向 Runtime 提交规范化的 `durationSeconds`。buffer 继续使用
   probe 收敛出的只读值。
4. 开始采集。没有可靠总量时只显示 indeterminate 与 elapsed time。
5. ArkDeck 等待 terminal Job，精确选中唯一的 published raw `trace.htrace`，以
   sensitive opt-in 读取，校验 offset、EOF、byte count 和 SHA-256。
6. 上述验证全部通过后才切换 Timeline。失败或取消保留之前已打开的文档。

全局 Job Inspector 才是阶段、取消策略、cleanup debt 与 terminal state 的权威。
Viewer 报错不能证明设备端清理已成功。

Target 区域显示 Runtime 已接管的 HDC 工具版本，例如 `hdc v3.2.0f`。该值来自
target/binding 事实，不会由 Trace Viewer 另行执行 HDC 探测。

## 无头真机采集

产品验收使用已安装、已签名的 ArkDeck Runtime。先读取当前 Catalog 与 operation 的
实时输入描述：

```bash
arkdeck agentd status
arkdeck doctor
arkdeck device list --json
arkdeck operation describe --operation capture.diagnostics@1 --json
```

创建一份绝对路径 JSON 文件，tags 必须来自同一 target 的当前 Trace probe。最小
trace-only 请求示例：

```json
{
  "captureHilog": false,
  "crashLogs": false,
  "durationSeconds": 10,
  "hilogFilters": [],
  "redactionProfile": "standard",
  "traceBufferKB": 8192,
  "traceCategories": ["sched", "freq", "ace", "app"],
  "uiComponentTree": false,
  "uiDump": false,
  "uiScreenshot": false
}
```

执行精确的 published operation。不得把 connect key、executable、argv 或 remote path 写入
inputs：

```bash
arkdeck agent run \
  --operation capture.diagnostics@1 \
  --target <adopted-target-id> \
  --inputs-file /absolute/path/to/trace-inputs.json \
  --json
```

若 ArkDeck 因信任、重连或 target 消歧暂停，只完成回执中说明的物理动作，然后使用
它输出的 `agent resume` 命令。不得用猜测身份重新发起一条 host command。成功回执
会给出 Job ID 与当前 Catalog digest。

检查并导出唯一的 Trace Artifact：

```bash
arkdeck artifact list --job <job-id> --allow-sensitive --json
arkdeck artifact export \
  --job <job-id> \
  --artifact <trace-artifact-id> \
  --destination /absolute/path/to/export-directory \
  --allow-sensitive \
  --json
```

合格条目必须同时满足：名称 `trace.htrace`、raw role、sensitive privacy、published status、
`application/octet-stream` media type、非空 bytes 和 64 位 lowercase SHA-256。候选者重复、
`outcomeUnknown` 或未结 cleanup residue 都不是合格验收。

## 使用开发者 CLI 解析

构建迁入后的 helper，并读取 SwiftPM 实际输出目录：

```bash
swift build --package-path Packages/ArkDeckKit --product arktrace
swift build --package-path Packages/ArkDeckKit --show-bin-path
```

使用 SwiftPM 裸产物时，必须显式传入锁定 parser 的绝对路径：

```bash
/absolute/swiftpm/bin/path/arktrace \
  --trace-streamer "$PWD/Packages/ArkDeckKit/ThirdParty/TraceStreamer/macx/trace_streamer" \
  inspect /absolute/path/to/trace.htrace

/absolute/swiftpm/bin/path/arktrace \
  --json \
  --trace-streamer "$PWD/Packages/ArkDeckKit/ThirdParty/TraceStreamer/macx/trace_streamer" \
  summary /absolute/path/to/trace.htrace
```

可用 commands 为 `doctor`、`licenses`、`inspect`、`summary`、`processes`、`threads`、
`query`、`context` 和 `analyze`。使用 `arktrace --help` 查看封闭 typed filters。全局硬边界
包括 `--timeout-ms`、`--max-rows`、`--max-events` 和 `--max-output-bytes`；`--no-cache`
使用 session-owned 临时数据库。

SwiftPM 裸可执行文件是开发产物，不是完整发布：它故意不携带 reviewed license 与
self-test 资源布局，因此 `licenses` 和 `doctor --self-test` 会 fail closed。App 携带自己固定的
parser 与许可文本，不使用 `PATH`。

## Timeline 操作

### 时间轴

| 按键 | 动作 |
|---|---|
| <kbd>W</kbd> / <kbd>S</kbd> | 以指针位置为锚点放大 / 缩小 |
| <kbd>A</kbd> / <kbd>D</kbd> | 左移 / 右移 |
| <kbd>F</kbd>, <kbd>[</kbd>, <kbd>]</kbd> | 缩放到选中区间 |
| <kbd>←</kbd> / <kbd>→</kbd> | 同一轨道的前一 / 后一真实 event |
| <kbd>↑</kbd> / <kbd>↓</kbd> | 相邻可见轨道 |
| <kbd>Option</kbd>+<kbd>←</kbd>/<kbd>→</kbd> | 平移约一个 viewport 的 10% |
| <kbd>+</kbd> / <kbd>-</kbd> | 围绕 selection 或 viewport center 缩放 |
| <kbd>Return</kbd> · <kbd>0</kbd> · <kbd>Esc</kbd> | 选择 focused event · 重置缩放 · 清除选择 |
| <kbd>,</kbd> / <kbd>.</kbd> | 把最近的 flag 滚回视野 |
| <kbd>Ctrl</kbd>+<kbd>,</kbd> / <kbd>Ctrl</kbd>+<kbd>.</kbd> | 跳到上一个 / 下一个 flag |
| <kbd>M</kbd> / <kbd>Shift</kbd>+<kbd>M</kbd> | 把当前选区标记为 mark —— 临时 / 保留 |
| <kbd>Ctrl</kbd>+<kbd>[</kbd> / <kbd>Ctrl</kbd>+<kbd>]</kbd> | 在 mark 之间跳转 |

### 时间轴上的指针操作

| 按键 | 动作 |
|---|---|
| 拖动 | 框选时间区间；拖动任一边界可单独调整 |
| 滚动 | 横向平移 |
| <kbd>Option</kbd> 或 <kbd>Ctrl</kbd> + 滚动 | 以指针位置为锚点缩放 |
| 捏合 | 以指针位置为锚点缩放 |
| 点击时间标尺 | 在该时刻放置一个 flag |

### 搜索结果

| 按键 | 动作 |
|---|---|
| <kbd>↑</kbd> / <kbd>↓</kbd> | 上一条 / 下一条匹配，并在时间轴上跳到它 |
| <kbd>Return</kbd> | 跳到选中的匹配，并把 focus 交给 Timeline |

同一份目录也显示在 **帮助 → Trace Keyboard Shortcuts**。两份指南与 Help 窗口都由
同一份 code-owned catalog 合约测试锁定。

## 隐私与故障排查

- Trace Artifact 是 sensitive 并只留在本地。导出必须显式执行；Trace 路径不上传数据。
- Parser 缺失或 identity drift：重建 / 恢复受审的锁定 helper，不使用 `PATH` 中的同名文件替代。
- 设备 Job 成功但 parser 失败：保留不可变 Artifact，检查有界 parser diagnostic；不用重新采集掩盖 host parser 缺陷。
- Cache 验证失败：ArkDeck 会隔离并重建派生数据；删除或编辑 raw Trace 不是修复。
- 没有 timed events 可以是真实 capability 结果。它与 malformed schema、probe truncation 或 parser failure 是不同状态，UI 和 machine result 会分开表达。
