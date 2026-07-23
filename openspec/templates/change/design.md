# Change Design

## Context and constraints

- Approved proposal revision
- Core baseline
- Related specs/contracts/ADRs
- Current repository evidence

## Requirement mapping

| Requirement / AC | Design component | Verification |
| --- | --- | --- |
| — | — | — |

## Architecture and data flow

说明 shared Core、integration adapter 和 platform Port 的边界。

## Data and contract changes

列出 schema、migration、compatibility 和 versioning。无变化也要写明。

## Authority and production reachability

回答下列五项;纯文档或 host-only 无 effect 的 change 可写 `not applicable`,
但必须给出理由。本节只要求把判断写下来,不创造批准或就绪语义。

- Production composition root:生产路径的组装入口(不是测试或 fake 装配)。
- Authority 产生点:authority/permit/capability 的唯一产生位置;谁能构造它。
- Effect dispatch point:effect 实际派发的位置,以及 intent/outcome 的 durable 边界。
- Fake/simulation 与 production 的结构差异:正例为何不会跨过该差异。
- Facts/provenance:被信任的事实能否由同一调用方同时构造事实与其证明。

## Failure, cancellation, and recovery

列出正常、错误、取消、崩溃/重启和恢复路径。

## Security and privacy

权限、输入边界、日志脱敏、工具信任和供应链影响。

## Alternatives and ADRs

记录被拒方案和需要新增的 ADR。Design 不能藏产品规则。
