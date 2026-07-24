---
id: CHG-2026-031-macos-session-settings
revision: 1
status: proposed
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# macOS Session 输出与保留设置

## Why

DEC-006 已决定 macOS 产品默认值：

- Session 根目录为
  `~/Library/Application Support/ArkDeck/Sessions/<year>/<month>/<sessionUUID>/`；
- 总配额 20 GiB、安全余量 2 GiB；
- 保留期 90 天，清理顺序为 expired-first → `completedAt` 升序，pinned Session
  永不删除；
- 普通 Session 删尽后仍无法回到安全余量时，阻止新的 heavy writer 并提示用户。

这些值目前没有 App 设置面，也没有完整 production wiring。现有
`RockchipProductExecutionSettings.load()` 直接创建固定的 Application Support
`Sessions` 目录；`SessionRetentionController` 和
`HostStorageCoordinator.updateRetentionAdmission` 仅在 Storage 实现/测试中出现。
因此用户不能选择持久化输出目录、不能查看或调整配额/保留期，也没有产品调用点把
保留计划、实际清理结果与新的 heavy-writer 准入连接起来。

## What changes

### In scope

- 新增 versioned macOS Session settings facade，提供 DEC-006 的精确默认值，并以
  typed 值持久化总配额、安全余量和保留天数。无效、溢出或不完整值不进入生产组合。
- 默认根目录继续使用 App container 的 Application Support；自定义根目录只能来自
  用户选择的 read-write security-scoped bookmark。书签 stale、不可访问或解析到不同
  path 时明确要求重新选择，不静默回退到默认目录。
- 新增受控 Session retention catalog：只索引固定
  `<year>/<month>/<sessionID>` 结构、有效 Session identity 和 locked manifest；
  从 manifest 的 immutable `completedAt` 与当前保留天数得到 `expiresAt`，并用
  versioned retention metadata 保存 pin 状态。未知、损坏、符号链接或无法完整计量的
  Session 一律保留并使准入保持保守状态。
- 新增 App-owned shared storage runtime。Settings facade 与
  `RockchipFlashExecutionHost` 的生产组合读取同一配置 generation、使用同一
  `HostStorageCoordinator`；新 Job 的 Session 根和 retention admission 不再来自两套
  独立对象。
- retention refresh 先计算当前使用量与删除预览；当前使用量超过安全目标、存在无法
  计量的 Session 或清理结果未复核时，新的 heavy writer 保持 blocked。只有用户在 App
  内确认后才调用 `SessionRetentionController.apply`，随后重新扫描并以实际结果更新
  admission；取消预览或 App 重启不会被记成已清理。
- 新增 macOS Settings scene：展示/修改输出目录、配额、安全余量和保留期，支持恢复
  默认目录、Session pin/unpin、清理预览与二次确认，并显示当前使用量、预计释放量、
  保留的 pinned/未知 Session 和 heavy-writer 阻断原因。
- 中英文 String Catalog、accessibility identifier、contract tests 与 signed
  XCUITest 覆盖默认值、持久化、bookmark reopen/failure、catalog 防逃逸、pin 保护、
  清理确认和 production root wiring。

### Out of scope

- 不修改 `REQ-ART-006`、`REQ-STO-*`、manifest schema、journal schema 或 Core
  baseline；不改变 DEC-006 四项默认的结构。
- 不实现自动定时删除、后台清理、云同步、远程上传、组织级 MDM/managed-config
  脱敏策略、诊断包导出设置或 Windows/Linux UI。
- 不删除 raw/partial/未 final manifest 的 Session，不跨输出根迁移 Session，不跟随
  symlink，不把目录选择权限解释为执行外部程序权限。
- 不新增或放宽 Flash/HDC/device authority，不执行真实设备操作；实现与验证只使用
  host 侧临时 Session fixture。

### Observable behavior before/after

- Before：App 无 Session Settings；生产 Rockchip Session 根固定；retention 仅为未接线
  的 Storage API。
- After：用户可在 Settings 中管理输出根与保留策略；新生产 Session 使用经过
  bookmark/默认根校验的同一 settings generation；清理先预览再确认，pinned/未知数据
  不删，实际复核前新的 heavy writer fail closed。

## Scope(涉及的 Requirement/AC)

- Requirements:`REQ-ART-001`、`REQ-ART-006`、`REQ-STO-001`、
  `REQ-STO-003`、`REQ-STO-004`
- Canonical Acceptance:`AC-ART-006-02`、`AC-STO-001-01`、
  `AC-STO-003-01`、`AC-STO-004-01`
- Change-local Acceptance:`SSET-CONFIG-001`、`SSET-CATALOG-001`、
  `SSET-RETENTION-001`、`SSET-UI-001`
- Contracts/schemas:新增 macOS-local versioned settings/retention metadata；
  不进入 Core contract registry，不修改 locked manifest/journal schema
- 是否需要 Core baseline bump:否；`spec-impact.md` 记录 no-op delta

## Safety, privacy, and compatibility

- 删除只允许由用户确认的 plan 进入既有 `SessionRetentionController.apply`；plan
  中的 ID、catalog generation、sessions root 或 bookmark 任一漂移时作废并重新预览。
- catalog 只把有效 finalized Session 纳入可删除候选。active/partial、pinned、
  metadata 损坏、大小未知、identity/path 不一致或 symlink Session 均不可删除；不确定
  大小不得按 0 计入准入判断。
- 自定义根必须在 selection、bookmark resolution 和使用期保持同一 standardized path；
  security scope 生命周期覆盖 scan/create/apply，失效后不向默认根静默续写。
- quota 是产品内部上限，不声称预留物理磁盘；现有 per-volume snapshot、claim、
  revalidation 和 ENOSPC 语义保持。
- retention metadata 只保存 Session ID、时间、pin 和策略 generation，不保存设备标识、
  raw Artifact、用户 home 路径或 bookmark bytes；bookmark 只保存在 App preferences。
- rollback 为移除 Settings composition 并恢复 DEC-006 默认根；既有 Session 与 retention
  metadata 不迁移、不改写。自定义根失去授权时原数据保持原位并提示重新选择。
- macOS 需要重新验证 signed Sandbox bookmark 与 UI；Windows/Linux 仍为 not started，
  不产生支持声明。

## Approval and flow

本 proposal PR 只登记 change package，零产品实现、零 evidence、零状态翻转。正式批准
必须由独立 approval-only PR 完成；`TASK-SSET-001` 与 `TASK-SSET-002` 各自再走独立
readiness、implementation/evidence 和 done PR。`TASK-SSET-002` 依赖
`TASK-SSET-001 done`，不得在其判断门合入前投机形成 UI 实现 PR。
