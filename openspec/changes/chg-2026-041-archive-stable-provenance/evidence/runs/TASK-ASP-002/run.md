# TASK-ASP-002 run log

## implementation（2026-07-28；rockchip 去路径化 + 机械守卫）

### 授权与 base

readiness r1 #683（本任务段）→ **r5 #688**（实现中实测 trace-probes 亦为产品
运行时 pin，迁移面窄化为 rockchip 一处，trace 3 处并入 deferred 登记表）。
实现 base = r5 合入后的 protected `main` `663eb77`。独立 worktree
`agent/task-asp-002-r5`，commit 前核 `git branch --show-current`。

### 迁移前的反查（r5 立的新规矩，本任务第一次照做）

迁 `rockchip/loader-transition/1.0.0/registry.yaml` 之前，先对**其内容
哈希**做全仓反查，而不是只看谁 import 它：

| 反查面 | 结果 |
| --- | --- |
| 内容 SHA-256 `446df409…` 在 `Sources`/`Tests`/`scripts`/`.github` | **0 命中** |
| `INTEGRATION-PROFILES.lock.yaml` | **不在 lock**（0 命中） |
| `check_sdd.py` structured pins | 0 命中 |
| 读该文件的代码 | 仅 `probe.py:31`（按路径读，不校验内容哈希） |
| 命中该哈希的仓内位置 | 仅 CHG-2026-026 的两份**历史 evidence receipt**（`inputSHA256` 与一张表）——实测**无任何活体消费方**再校验 `inputSHA256`，它们记录的是当时的字节，不是活 pin |

结论：rockchip 的迁移不越 `Packages/**`。这与 trace-probes 的处境正相反
（其 `9d2a390b…` 被 `TraceProbeAdapter.swift:10` 的 `public static let
registrySHA256` 钉死），所以 r5 才把 trace 推迟。

### 变更（恰 5 个文件，零 `Packages/**`）

| 文件 | 变更 |
| --- | --- |
| `openspec/integrations/rockchip/loader-transition/1.0.0/registry.yaml` | `evidencePath` → `evidenceChange` + `evidenceRelativePath` |
| `scripts/rockchip_loader_transition_probe/probe.py` | 常量拆为 `SOURCE_EVIDENCE_CHANGE` + change-relative 路径；`SourceProvenance` 字段；receipt 形状；新增 `resolve_change_directory()`；drift 校验加一条；registry 解析器 |
| `scripts/rockchip_loader_transition_probe/test_probe.py` | 固件路径改经同一解析器；负例更名；新增 `evidence-change` 漂移用例 |
| `scripts/check_sdd.py` | 新增 `check_registry_change_paths()` + 显式 deferred 登记表，接入 `main()` |
| `scripts/test_check_sdd.py` | 新增 `RegistryChangePathGuardTests`（8 例） |

形态：

```
"evidenceChange":       "CHG-2026-026-macos-rockchip-flash-ui"
"evidenceRelativePath": "evidence/runs/TASK-RKFUI-001/clean-discovery-repin-2026-07-24.md"
```

`evidenceSHA256` 逐字节未动。change id 采 frontmatter 权威拼写（`CHG-` 前缀
大写、其余原样），与 ASP-001 的 `sourceChange` 同族。

### 守卫

扫描面 = `openspec/integrations/**` 与
`Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/**` 下**每个可解码
文本文件**。这是「registry/resource/receipt」的**故意取超集**：新的 provenance
文件不该因为起了个没人枚举过的名字就绕过守卫。不可解码（二进制 fixture）跳过。

deferred 登记表 **7 文件 / 15 处**，逐条写明期望次数与原因：

| 文件 | 期望 | 原因 |
| --- | --- | --- |
| `openspec/integrations/openharmony/readonly-probes.yaml` | 4 | `HDCReadOnlyProbeRegistry.swift` 钉住内容哈希并被运行时消费 |
| `openspec/integrations/openharmony/trace-probes/1.0.0/registry.yaml` | 3 | `TraceProbeAdapter.swift` 钉住内容哈希 |
| `Fixtures/HDC/Probes/1.0.0/registry.yaml` | 4 | 同 readonly |
| 同目录 4 个 receipt | 各 1 | 同 readonly |

三条判据（**双向**，登记表是欠债台账而非豁免章）：表外出现即 fail 并指名
文件与行；表内**多于**登记值 fail（防止借豁免夹带新债）；表内**少于**登记值
fail（防止悄悄还债不更账）。另加一条：登记的文件不存在也 fail。

### 测量

| 项 | 结果 |
| --- | --- |
| `check-sdd` | **0 error / 0 warning / 111 acceptance IDs** |
| `scripts/test_check_sdd.py` | 40 → **48 OK** |
| `scripts/rockchip_loader_transition_probe/test_probe.py` | 31 → **31 OK**（原地迁移，未丢用例） |
| `scripts/trace_capture/test_registry.py` | 4 OK |
| `scripts/trace_capture/test_capture.py` | 33 OK |
| `scripts/host_loop`（discover） | 638 OK（expected failures=1） |
| Swift（**非 `/private/tmp`** 检出 `~/asp2r5-verify`，已打本 patch） | `Executed 415 tests, with 1 test skipped and 0 failures`（exit 0，全量日志非截断读；`' failed` 出现 0 次） |

守卫落地前的实测面：全扫描面 `openspec/changes/` 字面量 **16 处 / 8 文件**；
迁完 rockchip 后 **15 处 / 7 文件**，与登记表逐文件精确相等。

### 反证（四条，全部如预期）

1. **守卫必红、撤销即失效**。在 rockchip registry 里种一处
   `"plantedViolation": "openspec/changes/chg-2026-026-…/evidence/x.md"`：
   守卫在位 → `ERROR …/registry.yaml: line 43 names a whole in-repo change
   path; …`，`check_sdd: 1 error`。把 `main()` 里的
   `check_registry_change_paths()` 一行删掉、**违例原样保留** →
   `check_sdd: 0 error`。拦住它的确实是这条新检查。
2. **登记值改小必红**。把 trace-probes 的 `(3, …)` 改成 `(2, …)` →
   `ERROR …/trace-probes/1.0.0/registry.yaml: carries 3 in-repo change paths
   but only 2 are registered as deferred (…); the extra ones are new debt…`。
3. **撤销 active-or-archive 解析必红**。把 `probe.py` 里
   `change_directory = resolve_change_directory(...)` 换回仓根 join →
   `test_probe.py` **FAILED (failures=5, errors=2)**。解析器是承重的。
4. **归档模拟（正面证明，本 change 的存在理由）**。在两份副本里把
   `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/` 移到
   `openspec/changes/archive/2026-07-28-chg-2026-026-macos-rockchip-flash-ui/`：

   | 形态 | 归档后 `test_probe.py` |
   | --- | --- |
   | 迁移后（r5） | **OK**（31） |
   | 迁移前（`origin/main`，整条仓内路径） | **FAILED (errors=31)** |

   且迁移后的解析器显式落在归档目录上，evidence 哈希仍与 registry pin 相等：

   ```
   resolved change dir : openspec/changes/archive/2026-07-28-chg-2026-026-macos-rockchip-flash-ui
   evidence sha256     : d0b5089954e19a4aba354846fe6108b2d5c89bfc12ab0396c2cd7eb4a082189a
   registry pin        : d0b5089954e19a4aba354846fe6108b2d5c89bfc12ab0396c2cd7eb4a082189a
   ```

### 移交与未闭合

- **trace-probes 3 处 + readonly 面 12 处 = 15 处 / 7 文件**留在登记表里，
  其哈希均为产品运行时 pin，须由一个持有 `Sources/**` 授权面的后续 change
  一并重钉。守卫的「少于登记值也 fail」这一条保证那次迁移不能不更账。
- 本任务不碰 `Packages/**`、不碰 lock、不碰 `validate_registry.py`。
