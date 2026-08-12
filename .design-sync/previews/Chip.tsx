import { Chip } from "@arkdeck/ds";

export const DeviceAndChannel = () => (
  <div style={{ display: "flex", gap: 8, flexWrap: "wrap", alignItems: "center" }}>
    <Chip tone="ok" icon="✓">
      已授权
    </Chip>
    <Chip tone="warn">加密未验证</Chip>
    <Chip tone="dim">未运行</Chip>
    <Chip tone="ok">运行中 · pid 2841</Chip>
  </div>
);

export const CapabilityProbe = () => (
  <div style={{ display: "flex", gap: 8, flexWrap: "wrap", alignItems: "center" }}>
    <Chip tone="ok">可用</Chip>
    <Chip tone="warn">无法确认</Chip>
    <Chip tone="dim">不存在</Chip>
  </div>
);

/** History/internal-runtime badges; they are not a v0.6 Flash page selector. */
export const HistoricalExecutionModes = () => (
  <div style={{ display: "flex", gap: 8, flexWrap: "wrap", alignItems: "center" }}>
    <Chip tone="planned" icon="◇">
      PLANNED
    </Chip>
    <Chip tone="simulated" icon="▤">
      SIMULATED · fixture-a3
    </Chip>
  </div>
);

export const SessionOutcome = () => (
  <div style={{ display: "flex", gap: 8, flexWrap: "wrap", alignItems: "center" }}>
    <Chip tone="ok" icon="✓">
      成功
    </Chip>
    <Chip tone="danger" icon="✕">
      失败
    </Chip>
    <Chip tone="dim" icon="⊘">
      已取消
    </Chip>
    <Chip tone="warn" icon="⚠">
      已中断 · 结果未知
    </Chip>
  </div>
);
