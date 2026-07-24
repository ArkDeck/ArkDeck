# Spec Impact — CHG-2026-031

## Classification

本 change 是 macOS platform/product composition。`REQ-ART-006` 已要求保留期、总配额
和 pinned Session，`AC-ART-006-02` 已规定普通 Session 清理、pin 保护与 heavy-writer
阻断；`REQ-STO-001/003/004` 已规定真实 volume identity、heavy-writer 准入和 soft
claim 边界。DEC-006 已决定默认根、20 GiB / 2 GiB / 90 天与独立 wiring change。
本 change 只实现上述既有规则的 macOS 设置与 production 调用点。

## No-op delta conclusion

- `openspec/specs/**`：零修改。
- `openspec/contracts/**`：locked manifest/journal/schema 零修改。
- canonical acceptance registry/index：零 ID 变化。
- Core baseline：保持 `CORE-2.1.0`。
- 新增 settings/retention metadata 仅为 macOS-local versioned persistence，不承载
  Core authority，也不进入 Core contract registry。

## Interpretation requiring maintainer review

本 proposal 选择“自动 refresh/阻断，用户查看 exact plan 后才 apply 删除”，而不是
启动时自动清理。该选择保持 pin/uncertainty fail-closed，并使 host-local destructive
effect 有显式确认；维护者批准本 change 即接受这一 macOS 产品触发语义。未来改为定时/
后台自动删除必须独立 change。

首次索引旧 finalized Session 时 pin 默认 false；一旦 retention metadata 存在，缺失、
损坏或 identity mismatch 都按 preserved-unknown 处理。若维护者不接受此前无 pin
入口的 Session 采用该一次性初始化规则，`TASK-SSET-001` 保持 blocked 并在批准前修订，
不得在实现期自行选择。
