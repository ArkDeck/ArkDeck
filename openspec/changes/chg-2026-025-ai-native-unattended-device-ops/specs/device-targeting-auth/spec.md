# Device Targeting and Rebinding Specification Delta

> Change:CHG-2026-025-ai-native-unattended-device-ops@r3
> Target capability:`openspec/specs/device-targeting-auth/spec.md`
> Baseline:CORE-2.1.0
> Proposed baseline:CORE-3.0.0

## ADDED Requirements

### Requirement: REQ-DEV-009 Human intervention is closed, explicit, and resumable

ArkDeck SHALL 仅在 Agent 无法完成的物理/系统配置动作或 Core 明确要求人类判断时暂停：
物理接线/按键/断电、设备解锁与首次信任弹窗、OS permission/picker/driver/helper/
udev/group/ACL/Keychain/签名凭据配置、TCP/UART 或歧义 USB identity 确认、
external/unknown HDC lifecycle 与持久配置/数据丢失 impact approval、
outcomeUnknown 风险处置，以及治理 approval/authorization。

暂停 SHALL 生成结构化 `humanActionRequired`，包含 category、reason、关联 Job/Step、
最小人工动作、禁止自动化面和完成后的 readOnly resume probe。人类动作完成后系统
SHALL 重新 probe 并从可信事实决定是否继续；聊天文本、按钮点击或时间经过 SHALL NOT
直接确认 identity/outcome 或提升 effect authority。不属于上述封闭集合的人工代跑命令、
含糊“设备窗口”或重复点击 SHALL 被视为未实现的自动化缺口，而不是合格产品流程。

#### Scenario: AC-DEV-009-01 首次设备信任后自动续跑

- GIVEN Job 因设备端首次信任弹窗而返回 `humanActionRequired(deviceTrustPrompt)`
- WHEN 人类在设备上完成信任，Agent 调用记录中声明的 readOnly resume probe
- THEN 系统只在 fresh device observation 与原 durable target 匹配后继续
- AND 人类确认文本本身不创建 binding、E1 capability 或 E2 standing authorization
