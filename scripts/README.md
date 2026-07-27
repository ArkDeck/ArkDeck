# scripts/ 边界地图(framework vs 产品工具)

TASK-DEC-001(chg-2026-040)交付的一页索引:`scripts/` 下每个一级条目
属于**自动化框架**(治理/守卫/循环,与 ArkDeck 产品语义无关)还是
**产品工具**(为某个 change 的设备/取证工作而生),以及各自的实例参数
落在哪里。新增一级条目时同步更新本文件——
`test_check_pr_paths.py::AutomationConfigTests` 以 `git ls-tree` 清点
对照,遗漏即红。

## 自动化框架(framework)

| 条目 | 职责 | 实例参数所在 |
| --- | --- | --- |
| `check_pr_paths.py` | PR allowed-paths 守卫:按 PR 的任务声明比对改动路径;无任务声明的 PR 落到敏感路径判定 | 敏感路径表 = `automation_config.json`(fail-closed 加载,见下);任务文法/Allowed paths 解析正则仍在模块内(语义硬化属 TASK-DEC-004) |
| `automation_config.json` | `check_pr_paths.py` 的实例数据正本(schema `arkdeck-automation-config/v1`,唯一内容键 `sensitive_paths`)。文件本身位于 `scripts/**`,受它自己声明的敏感规则保护;缺失/畸形 = 每次检查即 CheckError,绝不静默回退 | 本文件即实例参数 |
| `test_check_pr_paths.py` | 上述守卫的离线契约套件(含配置等价性锚、五类畸形 fixture、本 README 覆盖清点) | 无(纯测试) |
| `check_sdd.py` | SDD 一致性检查器:specs/changes/locks/registry 的 fail-closed 校验 | openspec 布局常量在模块内硬编码(收口不在 DEC-001 范围,台账已记) |
| `test_check_sdd.py` | 检查器契约套件(TASK-DEC-003 起接入 CI) | 无(纯测试) |
| `check-sdd.sh` | check-sdd 只读入口:解释器解析(ARKDECK_PYTHON → 本 checkout venv → 主 checkout 共享 venv → PATH),preflight 失败即 fail closed | 解释器覆盖 = `ARKDECK_PYTHON` |
| `bootstrap-sdd.sh` | 共享 `.venv-sdd` 的一次性人工初始化(check-sdd.sh 永不调用它) | base 解释器覆盖 = `ARKDECK_BOOTSTRAP_PYTHON` |
| `requirements-sdd.txt` | SDD venv 的依赖 pin(仅 guard job 安装;allowed-paths job 零安装——故 `automation_config.json` 必须 stdlib 可解析) | 本文件即 pin |
| `test_sdd_runtime_entry.py` | TASK-SDR-001 契约套件:共享运行时发现矩阵 | 无(纯测试) |
| `host_loop/` | 常驻循环(discovery/lease/worker/reviewer/recovery/transport):认领 ready 任务、开 agent PR、观测与调和 | owner/repo/API root/lease 命名空间/env 名等仍散在各模块;收口为 `instance.py` 属 TASK-DEC-002(待做) |
| `test_agent_pr_workflow.py` | `.github/workflows/` Agent PR 命名空间分区的封闭契约(禁能力扫描) | 无(纯测试) |
| `README.md` | 本文件 | — |

框架的消费侧在 `.github/workflows/agent-pr.yml` 与 `sdd-guard.yml`
(不在 `scripts/` 下):二者的 allowed-paths job 直跑
`check_pr_paths.py`,guard job 另跑两个检查器套件与 host_loop 套件。

## 产品工具(product,一 change 一目录)

| 条目 | 职责(出处 change) |
| --- | --- |
| `archive_characterization/` | DAYU200 归档特征扫描器(CHG-2026-003,已归档) |
| `e0_readback/` | E0 只读身份/模式读回 crib(CHG-2026-025) |
| `m0b_capture/` | M0B DAYU200 bring-up 采集 runbook(CHG-2026-006,人工执行) |
| `partition_decode/` | DAYU200 钉定镜像分区解码器(CHG-2026-009,离线只读) |
| `rockchip_component/` | Rockchip 组件的无签名源码钉定构建(TASK-BRC-002) |
| `rockchip_e0_probe/` | 本地签名 Sandbox E0 探针(Hardened Runtime 特征化) |
| `rockchip_loader_transition_probe/` | HDC → Loader 转换特征化探针(CHG-2026-026) |
| `trace_capture/` | TR-001 trace 探针/最小采集 runbook(CHG-2026-021,人工执行) |
| `ud_capture/` | 受控 UI Dump 采集 harness(CHG-2026-008) |
| `ui_dump_redaction/` | UI Dump 派生 golden 脱敏器(host-only 隐私边界) |

产品工具的实例参数(设备身份、镜像 pins、fixtures、脱敏词表)一律钉在
**各自目录内**(README + 数据文件),不进框架面;守卫与循环对它们零
依赖。`__pycache__/` 是未跟踪的 Python 字节码缓存,不属于任何一类。
