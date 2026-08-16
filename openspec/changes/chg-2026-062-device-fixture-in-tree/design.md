# Design

## 为什么是一个选择器，而不是两个开关

```text
                      FixtureMode.MODE
                             │
              ┌──────────────┴──────────────┐
              ▼                             ▼
      crashProbe                      traceWorkload
   armCrashProbe() 生效            reload driver 生效
   启动 ~12 s 后 abort             进程存活整个采集窗口
              │                             │
              ▼                             ▼
   HiLog 留下 fault block          稳定产出可比较的工作量
   GJ-5 崩溃 journey 可查          ArkTrace 闭环可前后比较
```

两种用途的**期望终态相反**：一个要求进程死掉，另一个要求进程活着。此前它们是两个独立
布尔量（`CrashProbe.ENABLED` 与一组 trace 开关），于是存在第三种状态——两者同时开启——
而那个状态对谁都不成立。实测后果是 crash probe 在默认开启的情况下打断了 ArkTrace 的三次
采集窗口，直到有人去翻 faultlog 才发现原因。

枚举把这个非法状态从类型上消除：`MODE` 只能取其一，`armCrashProbe()` 与 reload driver
各自检查 `MODE` 后决定是否生效，不存在"设了一半"。

## 路径权限的边界

```text
Allowed paths (TASK-DFX-001)
├── tests/**                                    ← 本 change 请求的新权限
├── openspec/changes/chg-2026-062-.../**        ← 四件套自身
└── evidence/runs/TASK-DFX-001/**               ← 该 Task 的 evidence

不覆盖：Packages/** · Catalog/** · ArkDeckApp/** · ArkDeck.xcodeproj/** · scripts/**
```

刻意不包含任何生产路径。即使本 Task 被后续 PR 引用，它也无法用来改动 Runtime、Provider、
Catalog 或门禁脚本本身——这正是 `AGENTS.md` 禁止"为通过门禁扩张 Allowed paths"所要防的。

## Runtime 耦合面

fixture 被 `WorkspaceProjectProfile.waterFlowDemo` 按下列 identity pin 住，本 change 只改
其中的**项目路径**一项：

| 耦合点 | 值 | 本 change 是否改动 |
|---|---|---|
| 项目路径 | LaunchAgent `ARKDECK_WORKSPACE_PROJECTS` | **是**（移入仓库） |
| 构建目标 | `--mode module -p module=entry@default` | 否 |
| 产物路径 | `entry/build/default/outputs/default/entry-default-unsigned.hap` | 否 |
| bundle / ability | `com.example.waterflowdemo` / `EntryAbility` | 否 |
| 崩溃签名 | `SIGABRT+WaterFlowCrashProbe_RecoverBack` | 否 |

重指路径有一个非显然约束：harness 的 CLI 工作目录由 workspace 根推导，所以
`agentd update --workspace-project` 必须与 `--harness-model-provider/-name/--harness-cli`
同车重传，否则被 `Harness local CLI working directory must be the validated demo-app project`
拒绝。已实测确认，并写入 README。

重指本身不替换 daemon 二进制（`--daemon` 指向已安装 bundle 时 `install()` 跳过复制），
因此 OpenHarmony 签名 receipt 的 `trustedDaemonApplicationSHA256` 不失配，
`workspace.sign-openharmony-hap@1` 全程保持 `available`。

## 签名材料

`build-profile.json5` 的 `signingConfigs` 提交为空数组。实测确认：无签名配置时
`assembleHap` 仍成功，只产出 unsigned HAP——而这正是
`workspace.sign-openharmony-hap@1` 消费的那一份，生产链路不依赖本地签名包。
需要本地签名时由开发者在 DevEco 的 Project Structure → Signing Configs 自行填写，
该文件因此会长期显示为本地修改，属预期。
