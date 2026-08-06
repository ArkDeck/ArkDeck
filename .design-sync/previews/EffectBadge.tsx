import { Card, Chip, DataTable, EffectBadge } from "@arkdeck/ds";

const hint = { margin: 0, fontSize: 12.5, lineHeight: 1.6, color: "var(--ad-ink-2)" };

const planColumns = [
  { key: "n", header: "#", mono: true },
  { key: "step", header: "step", mono: true },
  { key: "args", header: "参数摘要", mono: true },
  { key: "effect", header: "effect" },
];

export const EffectClassAxis = () => (
  <Card title="effect 分级 — blast radius 自左向右递增">
    <div style={{ display: "flex", gap: 10, flexWrap: "wrap", alignItems: "center" }}>
      <EffectBadge effect="hostOnly" />
      <EffectBadge effect="readOnly" />
      <EffectBadge effect="deviceMutation" />
      <EffectBadge effect="destructive" />
    </div>
    <p style={hint}>
      hostOnly 不接触设备;readOnly 只读设备状态;deviceMutation 改变可恢复状态;destructive
      覆写分区。形状 + 文字承载语义,不只靠颜色(AC-UX-005-01)。
    </p>
  </Card>
);

export const FlashPlanEffectColumn = () => (
  <Card title="Exact Plan — rk3568-5.0-full · Execute">
    <DataTable
      columns={planColumns}
      rows={[
        {
          id: "1",
          cells: {
            n: "1",
            step: "enterUpdater",
            args: "—",
            effect: <EffectBadge effect="deviceMutation" />,
          },
        },
        {
          id: "2",
          cells: {
            n: "2",
            step: "flashPartition",
            args: "boot · boot.img · 64MB",
            effect: <EffectBadge effect="destructive" />,
          },
        },
        {
          id: "3",
          cells: {
            n: "3",
            step: "flashPartition",
            args: "system · system.img · 2.1GB",
            effect: <EffectBadge effect="destructive" />,
          },
        },
        {
          id: "4",
          cells: {
            n: "4",
            step: "reboot + waitReconnect",
            args: "binding revision + 强证据",
            effect: <EffectBadge effect="deviceMutation" />,
          },
        },
        {
          id: "5",
          cells: {
            n: "5",
            step: "postflight verify",
            args: "版本/设备校验",
            effect: <EffectBadge effect="readOnly" />,
          },
        },
      ]}
    />
    <p style={hint}>整份计划在执行前已逐步分级,读者一眼看到 2 个 destructive 步骤。</p>
  </Card>
);

export const PlanOnlyLedger = () => (
  <Card
    title="Exact Plan — Plan only"
    action={<Chip tone="planned">◇ PLANNED — 不派发 deviceMutation/destructive</Chip>}
  >
    <DataTable
      columns={[...planColumns, { key: "status", header: "status" }]}
      rows={[
        {
          id: "1",
          cells: {
            n: "1",
            step: "enterUpdater",
            args: "—",
            effect: <EffectBadge effect="deviceMutation" />,
            status: <Chip tone="planned">notExecuted(planned)</Chip>,
          },
        },
        {
          id: "2",
          cells: {
            n: "2",
            step: "flashPartition",
            args: "boot · c9d2…41aa",
            effect: <EffectBadge effect="destructive" />,
            status: <Chip tone="planned">notExecuted(planned)</Chip>,
          },
        },
        {
          id: "3",
          cells: {
            n: "3",
            step: "flashPartition",
            args: "system · 8b07…9e35",
            effect: <EffectBadge effect="destructive" />,
            status: <Chip tone="planned">notExecuted(planned)</Chip>,
          },
        },
        {
          id: "4",
          cells: {
            n: "4",
            step: "reboot + waitReconnect",
            args: "binding revision + 强证据",
            effect: <EffectBadge effect="deviceMutation" />,
            status: <Chip tone="planned">notExecuted(planned)</Chip>,
          },
        },
        {
          id: "5",
          cells: {
            n: "5",
            step: "postflightVerify",
            args: "版本/设备校验",
            effect: <EffectBadge effect="readOnly" />,
            status: <Chip tone="planned">notExecuted(planned)</Chip>,
          },
        },
      ]}
    />
    <p style={hint}>
      完整计划含 2 个 destructive 步骤,全部 notExecuted(planned);mutation dispatch = 0。
    </p>
  </Card>
);
