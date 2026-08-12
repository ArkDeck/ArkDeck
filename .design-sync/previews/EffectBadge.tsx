import { Card, DataTable, EffectBadge } from "@arkdeck/ds";

const hint = { margin: 0, fontSize: 12.5, lineHeight: 1.6, color: "var(--ad-ink-2)" };

export const EffectClassAxis = () => (
  <Card title="effect 分级 — blast radius 自左向右递增">
    <div style={{ display: "flex", gap: 10, flexWrap: "wrap", alignItems: "center" }}>
      <EffectBadge effect="hostOnly" />
      <EffectBadge effect="readOnly" />
      <EffectBadge effect="deviceMutation" />
      <EffectBadge effect="destructive" />
    </div>
    <p style={hint}>
      hostOnly 不接触设备；readOnly 只读设备状态；deviceMutation 改变可恢复状态；destructive
      覆写分区。形状、符号和文字共同承载语义，不只靠颜色。
    </p>
  </Card>
);

/** v0.6 Flash details: collapse 14 exact steps into four readable stages. */
export const FlashDetailsEffectSummary = () => (
  <Card title="刷机详情 · exact plan 摘要">
    <DataTable
      columns={[
        { key: "stage", header: "计划阶段" },
        { key: "count", header: "步骤数", mono: true },
        { key: "effect", header: "最高 effect" },
      ]}
      rows={[
        {
          id: "prepare",
          cells: { stage: "准备与校验", count: "3", effect: <EffectBadge effect="hostOnly" /> },
        },
        {
          id: "loader",
          cells: {
            stage: "进入 Loader 与身份绑定",
            count: "4",
            effect: <EffectBadge effect="deviceMutation" />,
          },
        },
        {
          id: "write",
          cells: { stage: "写入分区", count: "1", effect: <EffectBadge effect="destructive" /> },
        },
        {
          id: "verify",
          cells: {
            stage: "回读、重启与验证",
            count: "6",
            effect: <EffectBadge effect="readOnly" />,
          },
        },
      ]}
    />
    <p style={hint}>
      正常页面默认折叠此表；开发者需要排障时再展开。Flash 主界面不显示 plan-only 或 simulated
      模式切换。
    </p>
  </Card>
);
