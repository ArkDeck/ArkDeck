# TASK-ASP-001 run log

## implementation（2026-07-28；device-observation provenance 去路径化）

### 授权与 base

readiness r1 #674 → r2 #675（勘察补全、trace/rockchip 移交 ASP-002）→
**r3 #677**（因产品运行时 pin 窄化到 device-observation 一对）。实现 base =
r3 合入后的 protected `main`；r3 的 source pin 于该 base 复核零漂移。

### 变更（恰 6 个文件）

| 文件 | 变更 |
| --- | --- |
| `openspec/integrations/openharmony/device-observation-probes.yaml` | `provenance.sourcePath` → `sourceChange` + `sourceEvidence` |
| `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/DeviceObservation/1.0.0/registry.yaml` | 同上（bundled 副本，逐字节相同） |
| `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/DeviceObservation/1.0.0/resources.json` | `registryCopy` 的 sha256/bytes 级联 |
| `openspec/integrations/INTEGRATION-PROFILES.lock.yaml` | 三条 sha256 级联（canonical / 副本 / manifest） |
| `openspec/integrations/openharmony/profile.md` | 引用的 registry SHA-256 同步 |
| `openspec/platforms/macos/profile.md` | 同上 |
| `Packages/.../HDCDeviceObservationRegistryContractTests.swift` | **新增**两条形态断言（迁移前该测试完全不解码 `provenance`） |

形态：

```
"sourceChange":   "CHG-2026-024-hdc-device-snapshot-registration"
"sourceEvidence": "evidence/runs/TASK-I24-001/run.md"
```

change id 采 frontmatter 的权威拼写（`CHG-` 前缀大写、其余原样）；
`sessions[].mergeOID`、`rawLocation`、`repositoryGoldenFixture`、
`evidenceClass` 逐字保留。

### 二值门（逐项实测）

- **字面量归零**：device-observation 一对内 `openspec/changes/` = **0**；
- **正副本仍字节一致**：canonical 与 bundled 副本 SHA-256 相等
  （`79814e45901ab7e4…`）；
- **语义字段零 diff**：迁移前后 entry 除 `provenance` 外逐字段深度相等
  （脚本内断言，不等即 FATAL）；
- **哈希级联闭合**：lock 三条、pack manifest 一条、两个 profile 各一处
  引用全部同步为新值；
- **旧哈希 `cc920212…` 在活跃引用面零残留**；全仓仅余一处，在
  `chg-2026-024/evidence/runs/TASK-I24-001/run.md` 的实现记录里——那是
  **I24-001 当时实测的历史事实**，evidence 记录历史值，改它等于伪造记录，
  故**刻意不动**。

### 变异反证（新断言确实在守）

| 变异 | 结果 |
| --- | --- |
| 把 `sourceEvidence` 改回仓内绝对路径 | **3 失败** |
| 删除 `sourceChange` 字段 | **11 失败**（解码即崩） |
| 还原 | **0 失败** |

### 验证（**非 `/private/tmp`** 检出 `~/asp-verify`）

- Swift 全量 **415 tests / 1 skipped / 0 failures（0 unexpected）**
  = r3 基线 413 + 新增 2；
- `check-sdd` **0 error / 0 warning / 111 acceptance IDs`。

### AC 结论（实现面）

- **`ASP-SHAPE-001` = PASS**：device-observation 一对零字面量；provenance
  具 `sourceChange` + `sourceEvidence`；契约测试新增形态断言并经变异证伪。
- **`ASP-CASCADE-001` = PASS**：lock / manifest / 两 profile 哈希一致；
  Swift 非 `/private/tmp` 零失败；`check-sdd` 0/0/111；语义字段 diff 为空；
  正副本字节一致（r3 认定的等价判据，因 device-observation 无
  `sourceSHA256`）。
- `ASP-GUARD-001` 属 TASK-ASP-002，未涉及。

### 遗留与后续（如实记录）

- **CHG-2026-024 的归档死结自此解除**：其 evidence 不再被任何仓内精确路径
  引用（归档 PR 独立走）。
- **移出本 change 的部分**（r3 记录）：`readonly-probes.yaml` + 副本 + 4 个
  receipt 的同类引用**未迁移**——其 SHA-256 被
  `Sources/ArkDeckOpenHarmony/HDCReadOnlyProbeRegistry.swift` 三常量钉死并由
  `HDCProduction.swift` 运行时消费，需 `Sources/**` 授权。
- trace-probes 与 rockchip loader-transition 的 4 处按 r2 归 TASK-ASP-002。
- 三轮 readiness 更正的根因均为「勘察少看一层」（兄弟测试全树枚举 → 其他键
  形态 → 产品哈希 pin）；本轮消费面已逐层查至 `Sources/`。
